import SwiftUI
import AppKit

struct PathBarView: View {
    @Binding var currentPath: URL
    /// Drop support: needs fileOps. When nil, breadcrumbs are not drop targets.
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil
    /// Embedded in the combined top bar (breadcrumbs + search in one row):
    /// skips its own padding/background/divider — the container draws chrome once.
    var hidesChrome = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editError: String? = nil
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)

            if isEditing {
                TextField("Type a path, ~ allowed — ⏎ to go, Esc to cancel", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .resetsCursorOnExit()
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editText) { _, _ in editError = nil }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        FFTheme.controlShape
                            .stroke(editError == nil ? Color.secondary.opacity(0.3) : Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .help(editError ?? "Type a folder path — Enter to go, Esc to cancel")
                    .onAppear { editFocused = true }
            } else {
                breadcrumbs
            }

            Spacer()

            // Visible affordance for path editing (was double-click-only before).
            ToolbarActionButton(icon: "pencil", label: "Edit path (⌘L) — double-click breadcrumbs also works") { startEditing() }

            // No Copy-path button here: the main toolbar already copies the
            // selection-or-current-path with the same semantics + toast.
            ToolbarActionButton(icon: "arrow.up.right.square", label: "Reveal current folder in Finder") {
                FinderReveal.reveal([currentPath])
            }
        }
        .padding(.horizontal, hidesChrome ? 0 : 12)
        .padding(.vertical, hidesChrome ? 0 : 6)
        .background {
            if !hidesChrome { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .bottom) {
            if !hidesChrome { Divider().opacity(0.6) }
        }
        .background(
            // ⌘L focuses path editing from anywhere.
            Button("") { startEditing() }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        )
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(pathComponents, id: \.path) { component in
                    BreadcrumbDropWrapper(component: component,
                                          isCurrent: component == currentPath,
                                          fileOps: fileOps,
                                          onReload: onReload,
                                          onNavigate: { currentPath = component })

                    if component != pathComponents.last {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .help("Double-click to edit path (⌘L)")
        .onTapGesture(count: 2) {
            startEditing()
        }
    }

    private var pathComponents: [URL] {
        var components: [URL] = []
        var url = currentPath
        components.append(url)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            components.insert(url, at: 0)
        }
        // macOS symlinked roots (/tmp → /private/tmp, same for /var and /etc):
        // the resolved path would show "/ › private › tmp …" — drop the
        // "/private" hop so the bar reads "/ › tmp …" like Finder/Terminal.
        // Display-only: every crumb still navigates to its real (resolved) URL.
        if components.count >= 3,
           components[0].path == "/",
           components[1].lastPathComponent == "private",
           ["tmp", "var", "etc"].contains(components[2].lastPathComponent) {
            components.remove(at: 1)
        }
        return components
    }

    private func startEditing() {
        editText = currentPath.path
        editError = nil
        isEditing = true
        // Focus is set via .focused + onAppear.
    }

    private func cancelEdit() {
        editError = nil
        isEditing = false
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editError = "Path is empty"
            NSSound.beep()
            return
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        // Kanonski oblik (/tmp → /private/tmp) da poređenja sa currentPath
        // i kolone/sidebar vide isti folder bez obzira na uneti oblik.
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            editError = "Folder not found: \(expanded)"
            NSSound.beep()
            return
        }
        guard FileItem.isBrowsableFolder(url) else {
            editError = "Not a browsable folder (packages open instead)"
            NSSound.beep()
            return
        }
        editError = nil
        isEditing = false
        // Ista putanja: bez promene nema onChange -> nema reload-a, pa eksplicitno.
        // Symlink-oblici (/tmp vs /private/tmp) su isti folder — bez lažne navigacije.
        if !ffSamePath(url, currentPath) { currentPath = url } else { onReload?() }
    }

}

// MARK: - Breadcrumb drop wrapper (state per crumb)

// One breadcrumb crumb that also accepts file drops onto its folder.
// Plain @State highlight (no observable object per crumb).
private struct BreadcrumbDropWrapper: View {
    let component: URL
    let isCurrent: Bool
    let fileOps: FileOperationsService?
    let onReload: (() -> Void)?
    let onNavigate: () -> Void

    @State private var isTargeted = false
    @State private var dropIsCopy = false
    @State private var dropSources: [URL] = []

    var body: some View {
        let label = Button {
            onNavigate()
        } label: {
            Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isCurrent ? Color.accentColor.opacity(0.13) : Color.clear)
                .clipShape(FFTheme.controlShape)
                .overlay(
                    FFTheme.controlShape
                        .strokeBorder(Color.accentColor.opacity(isCurrent ? 0.35 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help(component.path)

        if let fileOps, let onReload {
            DropHighlight(isTargeted: isTargeted, isCopy: dropIsCopy) { label }
                .onDrop(of: [.fileURL, .text],
                        delegate: BreadcrumbDropDelegate(component: component,
                                                         fileOps: fileOps,
                                                         onReload: onReload,
                                                         isTargeted: $isTargeted,
                                                         dropIsCopy: $dropIsCopy,
                                                         sources: $dropSources))
                // Drag-out: folder proxy to Finder (same as sidebar rows).
                .onDrag { FileDragSupport.provider(for: [component]) }
        } else {
            label
                .onDrag { FileDragSupport.provider(for: [component]) }
        }
    }
}

/// Struct delegate (see RowDropDelegate): zero cost until a drag hovers.
/// Resolves source URLs on hover so the volume rule drives the indicator —
/// same as folder rows (previously always showed Option-only, no volume check).
private struct BreadcrumbDropDelegate: DropDelegate {
    let component: URL
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool
    @Binding var dropIsCopy: Bool
    @Binding var sources: [URL]

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        sources = []
        dropIsCopy = NSEvent.modifierFlags.contains(.option)
        FileDropSupport.hoverCursor(valid: true)
        let dest = component
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { return }
            sources = urls
            dropIsCopy = !FileDropSupport.shouldMove(sources: urls, destination: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let copy: Bool
        if sources.isEmpty {
            copy = NSEvent.modifierFlags.contains(.option)
        } else {
            copy = !FileDropSupport.shouldMove(sources: sources, destination: component)
        }
        dropIsCopy = copy
        return DropProposal(operation: copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        sources = []
        FileDropSupport.hoverCursor(valid: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        FileDropSupport.hoverCursor(valid: false)
        let dest = component
        let ops = fileOps
        let reload = onReload
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
        }
        return true
    }
}
