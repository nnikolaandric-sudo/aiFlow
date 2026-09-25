import SwiftUI
import AppKit

// MARK: - Git Views (bedževi, diff, repo panel, history)
//
// Sloj iznad GitService-a. Namjerno sitno i u postojećem vizuelnom jeziku
// (FFTheme kartice, caption fontovi) — Git je dio file managera, ne nova app.

// MARK: - Badge (M/A/D/?/!/R uz fajl u browseru)

/// Kompaktni status bedž: slovo u boji + staged tačka.
/// Koriste ga SwiftUI redovi (Grouped list, Icons, Columns); AppKit tabela
/// (NativeFileTable) crta isti tekst preko `GitService.status(for:)`.
struct GitBadgeView: View {
    let status: GitFileStatus?
    var size: CGFloat = 10

    var body: some View {
        if let st = status {
            HStack(spacing: 3) {
                // "New" instead of Git's "?" — a question mark next to a file
                // reads like an error, not "Git doesn't track this yet".
                Text(st.state == .untracked ? "New" : st.state.rawValue)
                    .font(.system(size: st.state == .untracked ? size - 1 : size, weight: .bold,
                                  design: st.state == .untracked ? .rounded : .monospaced))
                    .foregroundStyle(st.state.color)
                    .frame(minWidth: 12)
                    .help("\(st.state.label)\(st.staged ? " • staged" : "")\(st.unstaged ? " • unstaged" : "")")
                if st.staged {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .help("Staged")
                }
                if st.state == .conflicted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size - 1))
                        .foregroundStyle(.red)
                        .help("Merge conflict")
                }
            }
        }
    }
}

// MARK: - Diff rendering

/// Jedna diff linija sa VS Code bojama (crveno/Zeleno), ali FinderFlow card stilom.
private struct GitDiffLine: View {
    let text: String

    var body: some View {
        let kind = kindOf(text)
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(kind.color)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(kind.background)
    }

    enum Kind {
        case added, removed, hunk, header, context
        var color: Color {
            switch self {
            case .added:   return Color(nsColor: .systemGreen).opacity(0.95)
            case .removed: return Color(nsColor: .systemRed).opacity(0.95)
            case .hunk:    return Color.accentColor
            case .header:  return Color.secondary
            case .context: return Color.primary.opacity(0.85)
            }
        }
        var background: Color {
            switch self {
            case .added:   return Color.green.opacity(0.10)
            case .removed: return Color.red.opacity(0.10)
            case .hunk:    return Color.accentColor.opacity(0.08)
            default:       return Color.clear
            }
        }
    }

    private func kindOf(_ t: String) -> Kind {
        if t.hasPrefix("+") && !t.hasPrefix("+++") { return .added }
        if t.hasPrefix("-") && !t.hasPrefix("---") { return .removed }
        if t.hasPrefix("@@") { return .hunk }
        if t.hasPrefix("diff ") || t.hasPrefix("index ") || t.hasPrefix("+++") || t.hasPrefix("---") { return .header }
        return .context
    }
}

/// Diff fajla sa [Stage] [Unstage] [Discard] akcijama (spec: klik na fajl → preview).
struct GitFileDiffView: View {
    let url: URL
    @ObservedObject var git = GitService.shared
    @State private var loadToken = 0
    @State private var diffText: String? = nil
    @State private var isLoading = true
    @State private var actionMsg: String? = nil
    var onReload: () -> Void = {}

    private var status: GitFileStatus? { git.status(for: url) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if isLoading {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("Reading diff…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if let diff = diffText {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.components(separatedBy: "\n").prefix(800), id: \.self) { line in
                            GitDiffLine(text: line.isEmpty ? " " : line)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if let msg = actionMsg {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).padding(.horizontal, 10).padding(.vertical, 4)
            }
            Divider().opacity(0.6)
            actions
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { load() }
        .onChange(of: url.path) { _, _ in load() }
        .onChange(of: git.version) { _, _ in load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            GitBadgeView(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let st = status {
                    Text("\(st.state.label)\(st.staged ? " • staged" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No changes").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(10)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let st = status, st.unstaged {
                Button("Stage") { stage() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            if let st = status, st.staged {
                Button("Unstage") { unstage() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if status != nil {
                Button("Discard…") { confirmDiscard() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .foregroundStyle(.red)
            } else {
                Text("Clean").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }

    private func load() {
        loadToken &+= 1
        let token = loadToken
        isLoading = true
        diffText = nil
        let target = url
        git.diffText(for: target) { text in
            DispatchQueue.main.async {
                guard token == self.loadToken, target == self.url else { return }
                self.diffText = text
                self.isLoading = false
            }
        }
    }

    private func stage() {
        git.stage([url]) { ok, msg in
            actionMsg = ok ? "Staged." : msg
            onReload()
        }
    }

    private func unstage() {
        git.unstage([url]) { ok, msg in
            actionMsg = ok ? "Unstaged." : msg
            onReload()
        }
    }

    private func confirmDiscard() {
        let st = status
        let alert = NSAlert()
        alert.messageText = "Discard changes in \"\(url.lastPathComponent)\"?"
        alert.informativeText = st?.state == .untracked
            ? "Untracked file will be permanently deleted (git clean -f). This cannot be undone."
            : "Tracked changes will be restored from HEAD. This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        git.discard([url], includeUntracked: true) { ok, msg in
            actionMsg = ok ? "Discarded." : msg
            onReload()
        }
    }
}

// MARK: - History

/// Historija fajla/repo-a: klik na commit → diff (spec: History tab u preview-u).
struct GitHistoryView: View {
    let url: URL
    let root: URL
    @ObservedObject var git = GitService.shared
    @State private var loadToken = 0
    @State private var commits: [GitCommit]? = nil
    @State private var selected: GitCommit? = nil
    @State private var commitDiff: String? = nil
    @State private var diffLoading = false
    @State private var diffToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.accentColor)
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                if commits != nil {
                    Text("\(commits?.count ?? 0)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .ffBadge()
                }
            }
            .padding(10)
            Divider().opacity(0.6)
            if let list = commits {
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                        Text("No commits yet").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(list, id: \.id, selection: $selected) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.message).font(.system(size: 12)).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(c.shortHash).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                Text(c.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(c.date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(c)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 120, maxHeight: 260)
                    Divider().opacity(0.6)
                    if diffLoading {
                        HStack { ProgressView().scaleEffect(0.7); Text("Loading commit…").font(.caption).foregroundStyle(.secondary) }
                            .padding(8)
                    } else if let d = commitDiff {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(d.components(separatedBy: "\n").prefix(400), id: \.self) { line in
                                    GitDiffLine(text: line.isEmpty ? " " : line)
                                }
                            }.padding(.vertical, 6)
                        }
                        .frame(maxHeight: 300)
                    } else {
                        Text("Select a commit to see the diff.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            } else {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("Reading history…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { load() }
        .onChange(of: url.path) { _, _ in load() }
        .onChange(of: selected) { _, c in
            guard let c else { commitDiff = nil; return }
            diffToken &+= 1
            let token = diffToken
            diffLoading = true
            git.showCommit(c.id, in: root) { text in
                DispatchQueue.main.async {
                    guard token == self.diffToken, self.selected?.id == c.id else { return }
                    diffLoading = false
                    commitDiff = text
                }
            }
        }
    }

    private func load() {
        loadToken &+= 1
        let token = loadToken
        diffToken &+= 1
        commits = nil
        selected = nil
        commitDiff = nil
        let target = url
        git.history(for: target) { list in
            DispatchQueue.main.async {
                guard token == self.loadToken, target == self.url else { return }
                self.commits = list
            }
        }
    }
}

// MARK: - Repo panel (folder/repo nivo: branch, changes, commit, pull/push)

/// Panel na nivou foldera/repozitorijuma (spec: Git sekcija sa Branch,
/// Changes, Commit message, [Commit], Pull/Push).
struct GitRepoPanel: View {
    let root: URL
    @ObservedObject var git = GitService.shared
    var onRevealFile: (URL) -> Void = { _ in }
    var onReload: () -> Void = {}

    @State private var commitMsg: String = ""
    @State private var actionMsg: String? = nil
    @State private var isBusy = false
    @State private var showNewBranch = false
    @State private var newBranchName: String = ""

    private var changes: [GitFileStatus] {
        git.statuses.values.sorted { $0.relativePath < $1.relativePath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            changesList
            Divider().opacity(0.6)
            commitBox
            Divider().opacity(0.6)
            remotes
            if let error = git.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(3).padding(.horizontal, 10).padding(.vertical, 4)
            }
            if let msg = actionMsg {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4).padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showNewBranch) {
            VStack(spacing: 12) {
                Text("New branch").font(.headline)
                TextField("branch-name", text: $newBranchName)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                HStack {
                    Button("Cancel") { showNewBranch = false }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        showNewBranch = false
                        createBranch()
                    }.keyboardShortcut(.defaultAction).disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text("Git").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                if git.isLoading { ProgressView().scaleEffect(0.6) }
            }
            HStack(spacing: 6) {
                Text("Branch:").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(git.branches) { b in
                        Button(b.isCurrent ? "✓ \(b.name)" : b.name) {
                            switchBranch(b.name)
                        }
                    }
                    Divider()
                    Button("New branch…") { newBranchName = ""; showNewBranch = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(git.branch ?? "—").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                Spacer(minLength: 4)
                if git.ahead > 0 {
                    Text("↑\(git.ahead)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).help("Commits ahead of upstream")
                }
                if git.behind > 0 {
                    Text("↓\(git.behind)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange).help("Commits behind upstream")
                }
            }
            Text("\(changes.count) change\(changes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var changesList: some View {
        Group {
            if changes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(git.isLoading ? "Reading status…" : "Working tree clean")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(changes, id: \.url) { st in
                            Button {
                                onRevealFile(st.url)
                                GitUIRequest.shared.showDiff(for: st.url)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(st.staged ? "✓" : "○")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(st.staged ? .green : .secondary)
                                        .frame(width: 14)
                                    GitBadgeView(status: st)
                                    Text(st.relativePath)
                                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private var stagedChanges: [GitFileStatus] {
        changes.filter(\.staged)
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit message").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. Fix sidebar resizing", text: $commitMsg)
                .textFieldStyle(.roundedBorder)
            Button("Commit") { commit() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(commitMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy || stagedChanges.isEmpty)
        }
        .padding(10)
    }

    private var remotes: some View {
        HStack(spacing: 8) {
            Button { pull() } label: { Label("Pull", systemImage: "arrow.down.to.line") }
                .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
            Button { push() } label: { Label("Push", systemImage: "arrow.up.to.line") }
                .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
            Spacer(minLength: 4)
            if isBusy { ProgressView().scaleEffect(0.6) }
        }
        .padding(10)
    }

    private func commit() {
        isBusy = true
        git.commit(in: root, message: commitMsg) { ok, msg in
            isBusy = false
            actionMsg = ok ? "Committed." : msg
            if ok { commitMsg = "" }
            onReload()
        }
    }

    private func pull() {
        isBusy = true
        actionMsg = nil
        git.pull(in: root) { ok, msg in
            isBusy = false
            actionMsg = ok ? "Pulled." : msg
            onReload()
        }
    }

    private func push() {
        isBusy = true
        actionMsg = nil
        git.push(in: root) { ok, msg in
            isBusy = false
            actionMsg = ok ? "Pushed." : msg
            onReload()
        }
    }

    private func switchBranch(_ name: String) {
        isBusy = true
        git.switchBranch(name, in: root) { ok, msg in
            isBusy = false
            actionMsg = ok ? "Switched to \(name)." : msg
            onReload()
        }
    }

    private func createBranch() {
        isBusy = true
        git.createBranch(newBranchName, in: root) { ok, msg in
            isBusy = false
            actionMsg = ok ? "Created \(newBranchName)." : msg
            onReload()
        }
    }
}

// MARK: - Status bar branch pill (main ▾ ↑2 ↓0 · 3 changes)

struct GitStatusBarPill: View {
    @ObservedObject var git = GitService.shared

    var body: some View {
        if let root = git.repoRoot, let branch = git.branch {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if git.ahead > 0 {
                    Text("↑\(git.ahead)").font(.system(size: 10, weight: .semibold))
                }
                if git.behind > 0 {
                    Text("↓\(git.behind)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if git.changeCount > 0 {
                    Text("• \(git.changeCount)").font(.system(size: 11))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .help(root.path)
        }
    }
}
