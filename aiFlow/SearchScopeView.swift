import SwiftUI
import AppKit

enum SearchScope: String, CaseIterable {
    case thisFolder          = "This Folder"
    case thisFolderRecursive = "This Folder & Subfolders"
    case desktop             = "Desktop"
    case documents           = "Documents"
    case downloads           = "Downloads"
    case home                = "Home Folder"
    case entireMac           = "Entire Mac"

    var icon: String {
        switch self {
        case .thisFolder:          "folder"
        case .thisFolderRecursive: "folder.fill.badge.plus"
        case .desktop:             "desktopcomputer"
        case .documents:           "doc"
        case .downloads:           "arrow.down.circle"
        case .home:                "house"
        case .entireMac:           "magnifyingglass"
        }
    }

    func baseURL(currentPath: URL) -> URL {
        let fm = FileManager.default
        switch self {
        case .thisFolder, .thisFolderRecursive:
            return currentPath
        case .desktop:
            return fm.urls(for: .desktopDirectory,  in: .userDomainMask).first ?? currentPath
        case .documents:
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? currentPath
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? currentPath
        case .home:
            return fm.homeDirectoryForCurrentUser
        case .entireMac:
            return fm.homeDirectoryForCurrentUser   // unused; Spotlight uses its own scope constant
        }
    }
}

struct SearchScopeView: View {
    let currentPath: URL
    @ObservedObject var searchEngine: SearchEngine
    /// Local-rank result count for `.thisFolder` (ContentView owns that
    /// pipeline — SearchEngine.results stays empty for this scope).
    var localResultCount: Int = 0
    /// Embedded in the combined top bar (breadcrumbs + search in one row):
    /// skips its own padding/background/divider — the container draws chrome once.
    var hidesChrome = false
    @FocusState private var searchFocused: Bool
    /// One field, Finder-style: the scope is a small menu inside the field
    /// (magnifier + chevron), the placeholder says where it searches
    /// ("Search Downloads"), and the hit count sits at the trailing edge.
    /// It used to be a separate "Scope" picker next to the field, and in the
    /// narrow top-right corner the two squeezed each other to "Fu…".
    var body: some View {
        HStack(spacing: 6) {
            scopeMenu

            TextField(placeholder, text: $searchEngine.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .focused($searchFocused)
                .resetsCursorOnExit()
                .help("Fuzzy name, several words, or an extension like .pdf. ⌘⇧F opens the file palette.")
                .onSubmit { rerunSearch() }
                // Esc clears the query and returns to the folder listing
                // (Finder behavior). Only when the field has focus.
                .onExitCommand {
                    guard !searchEngine.query.isEmpty else { return }
                    clearSearch()
                }
                .onChange(of: searchEngine.query) { _, newValue in
                    if newValue.isEmpty {
                        searchEngine.cancelSearch()
                    } else {
                        rerunSearch()
                    }
                }

            if !searchEngine.query.isEmpty {
                if searchEngine.isSearching {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Text("\(displayedCount)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(displayedCount == 0 ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((displayedCount == 0 ? Color.secondary : Color.accentColor).opacity(0.14)))
                        .fixedSize()
                        .help("\(displayedCount) \(displayedCount == 1 ? "match" : "matches")")
                }
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search (Esc)")
            } else if !searchFocused {
                Text("Find")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 28)
        .frame(minWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: searchFocused ? .textBackgroundColor : .quaternaryLabelColor).opacity(searchFocused ? 1 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                              lineWidth: searchFocused ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
        // Re-run "This Folder" search when user navigates to a different folder
        .onChange(of: currentPath) { _, newPath in
            guard !searchEngine.query.isEmpty,
                  searchEngine.selectedScope == .thisFolder ||
                  searchEngine.selectedScope == .thisFolderRecursive
            else { return }
            searchEngine.search(
                in: searchEngine.selectedScope.baseURL(currentPath: newPath))
        }
        .onChange(of: searchEngine.selectedScope) { _, _ in
            rerunSearch()
        }
    }

    /// Where the search looks, in words the placeholder can use.
    private var scopeName: String {
        switch searchEngine.selectedScope {
        case .thisFolder:          return currentPath.lastPathComponent.isEmpty ? "this folder" : currentPath.lastPathComponent
        case .thisFolderRecursive: return "\(currentPath.lastPathComponent) and subfolders"
        case .entireMac:           return "this Mac"
        default:                   return searchEngine.selectedScope.rawValue
        }
    }

    private var placeholder: String { "Search \(scopeName)" }

    /// Magnifier + chevron: the scope menu. A non-default scope shows its own
    /// icon in the accent color, so a search of the whole Mac never looks
    /// like a folder search.
    private var scopeMenu: some View {
        Menu {
            Picker("Search In", selection: $searchEngine.selectedScope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Label(scope.rawValue, systemImage: scope.icon).tag(scope)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: searchEngine.selectedScope == .thisFolder ? "magnifyingglass" : searchEngine.selectedScope.icon)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(searchEngine.selectedScope == .thisFolder ? Color.secondary : Color.accentColor)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search in: \(searchEngine.selectedScope.rawValue)")
    }

    /// `.thisFolder` is ranked locally by ContentView (no SearchEngine
    /// enumeration); other scopes report SearchEngine's result count.
    private var displayedCount: Int {
        searchEngine.selectedScope == .thisFolder ? localResultCount : searchEngine.results.count
    }

    private func clearSearch() {
        searchEngine.query = ""
        searchEngine.cancelSearch()
    }

    private func rerunSearch() {
        guard !searchEngine.query.isEmpty else {
            searchEngine.cancelSearch()
            return
        }
        // `.thisFolder`: cancel any engine search and let ContentView's local
        // rank pipeline handle it — the old code ran BOTH (double enumeration
        // + double ranking for the same query).
        if searchEngine.selectedScope == .thisFolder {
            searchEngine.cancelSearch()
            return
        }
        searchEngine.search(
            in: searchEngine.selectedScope.baseURL(currentPath: currentPath))
    }
}
