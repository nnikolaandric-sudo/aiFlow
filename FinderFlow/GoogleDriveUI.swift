import SwiftUI
import AppKit

// MARK: - Google Drive nativni UI (sidebar + settings + bedževi)
//
// Pravila:
// - API nalozi (OAuth, mirror) i lokalni Drive folderi (Drive for Desktop)
//   prikazuju se ZAJEDNO u sidebar "Google Drive" sekciji — korisnik ne mora
//   da zna koji je koji, oba rade nativno (dupli klik, preview, editor).
// - Sync status je uvek vidljiv (badge + tekst), greške imaju akciju (Retry/Connect).
// - .gdoc/.gsheet/.gslides stubovi se otvaraju u browseru, ne u editoru.

// MARK: - Sidebar sekcija

struct GoogleDriveSidebarSection: View {
    @Binding var currentPath: URL
    @Binding var selection: SidebarItem?
    @ObservedObject var gdrive = GoogleDriveSyncService.shared
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil

    @State private var localMounts: [GoogleLocalDrive.LocalMount] = []
    @State private var dropTargetPath: String? = nil

    var hasAnything: Bool {
        !gdrive.accounts.isEmpty || !localMounts.isEmpty
    }

    var body: some View {
        // Loop-invariantno: ranije se currentPath.standardized računao jednom
        // po nalogu po renderu (~10µs svaki).
        let curStd = currentPath.standardizedFileURL.path
        Section {
            // API nalozi (mirror) — pravi nativni Drive bez Drive aplikacije
            ForEach(gdrive.accounts) { acc in
                let root = acc.mirrorRoot()
                Button {
                    go(root)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.shortLabel)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(statusText(for: acc.id))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        statusIcon(for: acc.id)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .background(curStd == root.standardizedFileURL.path
                                ? Color.accentColor.opacity(0.13) : Color.clear)
                    .clipShape(FFTheme.controlShape)
                }
                .buttonStyle(.plain)
                .tag(SidebarItem.location(root))
                .overlay(
                    FFTheme.controlShape
                        .strokeBorder(Color.accentColor, lineWidth: dropTargetPath == root.path ? 2 : 0)
                        .background(
                            FFTheme.controlShape
                                .fill(Color.accentColor.opacity(dropTargetPath == root.path ? 0.10 : 0))
                        )
                        .allowsHitTesting(false)
                )
                .onDrop(of: [.fileURL, .text],
                        delegate: DriveAccountDropDelegate(destination: root,
                                                           fileOps: fileOps,
                                                           onReload: onReload,
                                                           isTargeted: Binding(
                                                               get: { dropTargetPath == root.path },
                                                               set: { dropTargetPath = $0 ? root.path : nil }
                                                           )))
                .onDrag { FileDragSupport.provider(for: [root]) }
                .contextMenu {
                    Button("Sync Now") { gdrive.sync(accountID: acc.id) }
                        .disabled(gdrive.status(for: acc.id).isSyncing)
                    Button("Open in Browser") { gdrive.openInBrowser(accountID: acc.id) }
                    Button("Show Mirror in Finder") {
                        NSWorkspace.shared.selectFile(root.path, inFileViewerRootedAtPath: "")
                    }
                    Divider()
                    Button("Disconnect…", role: .destructive) { gdrive.disconnect(accountID: acc.id) }
                }
            }

            // Lokalni Drive for Desktop folderi (ako postoje pored API naloga)
            ForEach(localMounts, id: \.url) { mount in
                // Preskoči ako je isti email već povezan kao API nalog sa mirrorom
                // (da ne dupliramo) — ali prikaži ako API nalog ne postoji.
                if !isCoveredByAPI(mount) {
                    Button {
                        go(mount.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cloud.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 14))
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mount.email ?? mount.url.lastPathComponent)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Local sync")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(SidebarItem.location(mount.url))
                    .overlay(
                        FFTheme.controlShape
                            .strokeBorder(Color.accentColor, lineWidth: dropTargetPath == mount.url.path ? 2 : 0)
                            .background(
                                FFTheme.controlShape
                                    .fill(Color.accentColor.opacity(dropTargetPath == mount.url.path ? 0.10 : 0))
                            )
                            .allowsHitTesting(false)
                    )
                    .onDrop(of: [.fileURL, .text],
                            delegate: DriveAccountDropDelegate(destination: mount.url,
                                                               fileOps: fileOps,
                                                               onReload: onReload,
                                                               isTargeted: Binding(
                                                                   get: { dropTargetPath == mount.url.path },
                                                                   set: { dropTargetPath = $0 ? mount.url.path : nil }
                                                               )))
                    .onDrag { FileDragSupport.provider(for: [mount.url]) }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(mount.url.path, inFileViewerRootedAtPath: "")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Google Drive")
                Spacer()
                if gdrive.accounts.contains(where: { gdrive.status(for: $0.id).isSyncing }) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
            }
        } footer: {
            if gdrive.accounts.isEmpty && localMounts.isEmpty {
                Text("Connect a Google account in Settings → Google Drive — works without the Drive app.")
            }
        }
        .onAppear { refreshLocal() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshLocal() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshLocal() }
    }

    private func go(_ url: URL) {
        // Oznaka prvo, navigacija u sljedećem prolazu (vidi SidebarView.go).
        selection = .location(url)
        if currentPath == url {
            onReload?()
        } else {
            DispatchQueue.main.async { currentPath = url }
        }
    }

    private func refreshLocal() {
        DispatchQueue.global(qos: .utility).async {
            let mounts = GoogleLocalDrive.localMounts()
            DispatchQueue.main.async { localMounts = mounts }
        }
    }

    private func isCoveredByAPI(_ mount: GoogleLocalDrive.LocalMount) -> Bool {
        guard let email = mount.email?.lowercased(), !email.isEmpty else { return false }
        return gdrive.accounts.contains { $0.email.lowercased() == email }
    }

    private func statusText(for id: String) -> String {
        gdrive.status(for: id).displayText
    }

    @ViewBuilder
    private func statusIcon(for id: String) -> some View {
        switch gdrive.status(for: id) {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        case .syncing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
        case .needsAuth:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
        }
    }
}

// MARK: - Settings sekcija

struct GoogleDriveSettingsSection: View {
    @ObservedObject var gdrive = GoogleDriveSyncService.shared
    @State private var clientID: String = GoogleDriveAccountStore.clientID
    @State private var showClientHelp = false
    @AppStorage(GoogleDriveAccountStore.autoSyncKey) private var autoSyncStored: Bool = true

    var body: some View {
        Section {
            Text("Connect one or more Google accounts — aiFlow syncs them into a local mirror so they work natively (double-click, preview, editor, search) without the Google Drive app. The mirror lives in ~/Library/Application Support/FinderFlow/GoogleDrive/.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Client ID
            VStack(alignment: .leading, spacing: 6) {
                Text("Google Client ID (Desktop app)")
                    .font(.headline)
                Text("Google Cloud Console → APIs & Services → Enable APIs (Google Drive API) → Credentials → Create Credentials → OAuth client ID → Desktop app. Copy the Client ID here — one ID works for all accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("xxxx.apps.googleusercontent.com", text: $clientID)
                        .fontDesign(.monospaced)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        GoogleDriveAccountStore.clientID = clientID
                    }
                    .controlSize(.small)
                }
                if GoogleDriveAccountStore.clientID.isEmpty && !clientID.isEmpty {
                    Text("Unsaved — press Save.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !GoogleDriveAccountStore.clientID.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Client ID saved")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { GoogleDriveAccountStore.autoSyncEnabled },
                set: { GoogleDriveAccountStore.autoSyncEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-sync every 10 min")
                    Text("Only when accounts are connected. Manual Sync is always available from the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Connect
            HStack {
                Button {
                    Task { await gdrive.connect(clientID: GoogleDriveAccountStore.clientID.isEmpty ? clientID : GoogleDriveAccountStore.clientID) }
                } label: {
                    Label(gdrive.isConnecting ? "Connecting…" : "Connect Google Account…", systemImage: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.medium)
                .disabled(gdrive.isConnecting)
                if gdrive.isConnecting { ProgressView().scaleEffect(0.7) }
                Spacer()
                if !gdrive.accounts.isEmpty {
                    Button("Sync All") { gdrive.syncAll() }
                        .controlSize(.small)
                }
            }
            if let err = gdrive.connectError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Nalozi
            if gdrive.accounts.isEmpty {
                Text("No connected accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(gdrive.accounts) { acc in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 16))
                            .foregroundStyle(.green)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.shortLabel).fontWeight(.medium)
                            Text(acc.email)
                                .font(.caption).foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                                .lineLimit(1).truncationMode(.middle)
                            Text(acc.mirrorRoot().path)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fontDesign(.monospaced)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text(gdrive.status(for: acc.id).displayText)
                            .font(.caption)
                            .foregroundStyle(statusColor(for: acc.id))
                        Spacer()
                        if gdrive.status(for: acc.id).isSyncing {
                            Button("Cancel") { gdrive.cancelSync(accountID: acc.id) }
                                .controlSize(.small)
                        } else {
                            Button("Sync Now") { gdrive.sync(accountID: acc.id) }
                                .controlSize(.small)
                        }
                        Button("Open") { gdrive.openMirror(accountID: acc.id) }
                            .controlSize(.small)
                        Button {
                            gdrive.disconnect(accountID: acc.id)
                        } label: {
                            Label("Disconnect", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Disconnect account (mirror stays on disk)")
                    }
                    if case .error(let m) = gdrive.status(for: acc.id) {
                        Text(m).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .needsAuth = gdrive.status(for: acc.id) {
                        Button("Reconnect…") {
                            Task { await gdrive.connect(clientID: GoogleDriveAccountStore.clientID.isEmpty ? clientID : GoogleDriveAccountStore.clientID) }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    if let orph = gdrive.orphanedCount[acc.id], orph > 0 {
                        Text("\(orph) local files no longer exist on Drive (kept locally).")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }

            // Lokalni Drive for Desktop (info)
            LocalDriveInfoRow()
        } header: {
            FFSectionHeader(title: "Google Drive (native)", symbol: "cloud.fill", tint: .green)
        }
    }

    private func statusColor(for id: String) -> Color {
        switch gdrive.status(for: id) {
        case .error: return .red
        case .needsAuth: return .orange
        case .syncing: return .accentColor
        default: return .secondary
        }
    }
}

// MARK: - Drive account drop delegate

/// Drop target for a Google Drive account / local mount sidebar row.
/// Files dropped here are imported into the mirror root / mount folder.
private struct DriveAccountDropDelegate: DropDelegate {
    let destination: URL
    let fileOps: FileOperationsService?
    let onReload: (() -> Void)?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        fileOps != nil && FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func dropExited(info: DropInfo)  { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let fileOps else { return false }
        let dest = destination
        let reload = onReload ?? {}
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            // Cloud folders are almost always a different volume — default to copy.
            fileOps.importURLs(urls, to: dest, shouldMove: false, reload: reload)
        }
        return true
    }
}

private struct LocalDriveInfoRow: View {
    @State private var mounts: [GoogleLocalDrive.LocalMount] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drive for Desktop (local)")
                .font(.headline)
            if mounts.isEmpty {
                Text("No local Drive sync folder found — you don't need one. The API mirror above works on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(mounts, id: \.url) { m in
                    HStack {
                        Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                        Text(m.email ?? m.url.lastPathComponent)
                            .font(.caption).fontDesign(.monospaced)
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(m.url) }
                            .controlSize(.mini)
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let found = GoogleLocalDrive.localMounts()
                DispatchQueue.main.async { mounts = found }
            }
        }
    }
}
