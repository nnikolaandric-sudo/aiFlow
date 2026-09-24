import SwiftUI

// MARK: - Batch rename (FinderFlow+ power tool)
//
// Pipeline per file (each step optional, empty = skip):
//   1. Find & replace in the stem (case-insensitive by default)
//   2. Explicit base name (overrides the stem when set)
//   3. Prefix / suffix wrap
//   4. Sequence number suffix ("Name 001")
//   5. Case style + extension override
// Live preview with conflict flags; Apply skips conflicts and reports counts.
// Pure preview function at the bottom stays testable without SwiftUI.

enum BatchCaseStyle: String, CaseIterable, Identifiable {
    case keep = "Keep"
    case lower = "lowercase"
    case upper = "UPPERCASE"
    var id: String { rawValue }
}

struct BatchRenameOptions {
    var find = ""
    var replace = ""
    var ignoreCase = true
    var baseName = ""
    var prefix = ""
    var suffix = ""
    var addNumbering = false
    var numberStart = 1
    var numberPad = 3
    var numberSeparator = " "
    var caseStyle: BatchCaseStyle = .keep
    var changeExtension = false
    var newExtension = ""
}

/// Pure preview: original bare names → proposed bare names, in order.
func batchRenamePreview(originals: [String], options: BatchRenameOptions) -> [String] {
    originals.enumerated().map { idx, original in
        var stem = (original as NSString).deletingPathExtension
        let origExt = (original as NSString).pathExtension
        // Leading-dot files (".gitignore") have no stem — treat whole name as stem.
        if stem.isEmpty && !original.isEmpty { stem = original }

        if !options.find.isEmpty {
            if options.ignoreCase {
                stem = stem.replacingOccurrences(of: options.find, with: options.replace,
                                                 options: .caseInsensitive)
            } else {
                stem = stem.replacingOccurrences(of: options.find, with: options.replace)
            }
        }
        if !options.baseName.trimmingCharacters(in: .whitespaces).isEmpty {
            stem = options.baseName.trimmingCharacters(in: .whitespaces)
        }
        if !options.prefix.isEmpty { stem = options.prefix + stem }
        if !options.suffix.isEmpty { stem = stem + options.suffix }
        if options.addNumbering {
            let n = options.numberStart + idx
            let padded = String(format: "%0\(max(1, options.numberPad))d", n)
            stem = stem + options.numberSeparator + padded
        }
        switch options.caseStyle {
        case .keep: break
        case .lower: stem = stem.lowercased()
        case .upper: stem = stem.uppercased()
        }
        var ext = origExt
        if options.changeExtension {
            ext = options.newExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = (original as NSString).deletingPathExtension }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

struct BatchRenameSheet: View {
    let files: [FileItem]
    @ObservedObject var fileOps: FileOperationsService
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var options = BatchRenameOptions()
    /// Conflict set computed off-main + debounced — previously every keystroke
    /// ran O(n²) `seen.filter` + one `fileExists` stat per file on the render thread.
    @State private var conflictCache: Set<Int> = []
    @State private var conflictTask: Task<Void, Never>?
    @State private var existingNames: Set<String> = []

    private var originals: [String] { files.map(\.name) }
    private var proposed: [String] { batchRenamePreview(originals: originals, options: options) }

    /// Indices whose proposal collides (duplicate in batch, taken on disk, or invalid).
    private var conflictIndices: Set<Int> { conflictCache }

    private var changeCount: Int {
        proposed.enumerated().filter { $0.element != originals[$0.offset] }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.heroGradient)
                        .frame(width: 30, height: 30)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Rename \(files.count) Items")
                            .font(.system(size: 13, weight: .semibold))
                        if changeCount > 0 {
                            Text("\(changeCount) will change")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .ffBadge()
                        }
                    }
                    Text("Empty fields are skipped. Numbering follows the current sort order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    GroupBox("Find & Replace") {
                        VStack(spacing: 6) {
                            HStack {
                                TextField("Find", text: $options.find)
                                TextField("Replace", text: $options.replace)
                            }
                            Toggle("Ignore case", isOn: $options.ignoreCase)
                                .font(.caption)
                        }
                    }
                    GroupBox("Base / Affixes") {
                        VStack(spacing: 6) {
                            TextField("Base name (optional — overrides each name)", text: $options.baseName)
                            HStack {
                                TextField("Prefix", text: $options.prefix)
                                TextField("Suffix", text: $options.suffix)
                            }
                        }
                    }
                    GroupBox("Numbering") {
                        VStack(spacing: 6) {
                            Toggle("Add sequence number", isOn: $options.addNumbering)
                            if options.addNumbering {
                                HStack {
                                    Stepper("Start: \(options.numberStart)", value: $options.numberStart, in: 0...9999)
                                    Stepper("Digits: \(options.numberPad)", value: $options.numberPad, in: 1...6)
                                    TextField("Separator", text: $options.numberSeparator)
                                        .frame(width: 60)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    GroupBox("Case & Extension") {
                        VStack(spacing: 6) {
                            Picker("Case", selection: $options.caseStyle) {
                                ForEach(BatchCaseStyle.allCases) { c in Text(c.rawValue).tag(c) }
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Toggle("Set extension", isOn: $options.changeExtension)
                                if options.changeExtension {
                                    TextField("ext (no dot)", text: $options.newExtension)
                                }
                            }
                            .font(.caption)
                        }
                    }

                    // ── Live preview ──
                    Text("Preview")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(files.enumerated()), id: \.offset) { idx, _ in
                        HStack(spacing: 8) {
                            Text(originals[idx])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Text(proposed[idx])
                                .font(.system(size: 11, design: .monospaced))
                                .fontWeight(conflictIndices.contains(idx) ? .regular : .medium)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(conflictIndices.contains(idx) ? .red : .primary)
                            Spacer()
                            if conflictIndices.contains(idx) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 12)).foregroundStyle(.red)
                                    .help("Name taken, duplicated or invalid — will be skipped")
                            } else if proposed[idx] != originals[idx] {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 12)).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    if !conflictIndices.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                            Text("\(conflictIndices.count) \(conflictIndices.count == 1 ? "conflict" : "conflicts") will be skipped.")
                                .font(.caption)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxHeight: 380)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(changeCount == 0 ? "Nothing to Rename" : "Rename \(changeCount) Items") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(changeCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .onAppear { snapshotExistingNames(); scheduleConflictCheck() }
        .onChange(of: options.find) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.replace) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.ignoreCase) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.baseName) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.prefix) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.suffix) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.addNumbering) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.numberStart) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.numberPad) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.numberSeparator) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.caseStyle) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.changeExtension) { _, _ in scheduleConflictCheck() }
        .onChange(of: options.newExtension) { _, _ in scheduleConflictCheck() }
    }

    /// One directory listing per parent per sheet open; conflict checks then
    /// hit the in-memory set instead of stat-ing the disk per keystroke per
    /// file. All distinct parents — a search selection can span folders, and
    /// checking only the first file's folder missed real collisions.
    private func snapshotExistingNames() {
        let parents = Set(files.map { $0.url.deletingLastPathComponent() })
        var names = Set<String>()
        for parent in parents {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            names.formUnion(listing.map { $0.lowercased() })
        }
        existingNames = names
    }

    /// Pure conflict computation shared by the debounced preview task and
    /// apply(): apply must use FRESH results — the cache may lag keystrokes
    /// by 150ms, and filtering live proposals by a stale set applies renames
    /// the preview showed as conflicting (or skips ones it cleared).
    /// Invalid covers empty, "/", and reserved "." / ".." (same rules as the
    /// engine in FolderCreationService, which skips them at apply time).
    private func scheduleConflictCheck() {
        conflictTask?.cancel()
        let current = batchRenamePreview(originals: originals, options: options)
        let origs = originals
        let existing = existingNames
        conflictTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .userInitiated) { () -> Set<Int> in
                batchRenameConflicts(proposed: current, originals: origs, existing: existing)
            }.value
            guard !Task.isCancelled else { return }
            conflictCache = computed
        }
    }

    private func apply() {
        // FRESH snapshot: komentar je tvrdio FRESH a kod je koristio kes sa
        // onAppear — spoljna promena u medjuvremenu bi se primenila preko
        // ustajalog seta (engine je fail-closed pa ne bi pregazio, ali bi
        // preview lagao). Re-snapshot pre konflikata.
        snapshotExistingNames()
        let current = batchRenamePreview(originals: originals, options: options)
        let fresh = batchRenameConflicts(proposed: current, originals: originals, existing: existingNames)
        let pairs = files.enumerated().compactMap { idx, f -> (from: URL, toName: String)? in
            let target = current[idx]
            guard target != f.name, !fresh.contains(idx) else { return nil }
            return (f.url, target)
        }
        guard !pairs.isEmpty else { dismiss(); return }
        fileOps.batchRename(pairs, reload: onDone)
        dismiss()
    }
}

/// Preview/apply conflict set: duplicate within the batch, taken on disk, or
/// invalid. Pure — testable without SwiftUI.
func batchRenameConflicts(proposed: [String], originals: [String], existing: Set<String>) -> Set<Int> {
    var counts: [String: Int] = [:]
    counts.reserveCapacity(proposed.count * 2)
    for name in proposed { counts[name.lowercased(), default: 0] += 1 }
    var conflicts = Set<Int>()
    for (i, name) in proposed.enumerated() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || invalidNameReason(name) != nil {
            conflicts.insert(i); continue
        }
        if name == originals[i] { continue }
        if counts[name.lowercased(), default: 0] > 1 { conflicts.insert(i); continue }
        // Case-only rename ("readme"→"README") je isti item na case-insensitive
        // volumu — postojeci set uvek sadrzi sopstveno ime pa bi bez izuzeca
        // svaki case-only bio flagged kao konflikt (za razliku od AIPlanner-a
        // koji radi blocked.remove(own)). Dozvoli kad je jedini batch zahtev
        // za to ime bas sopstveni original.
        if name.lowercased() == originals[i].lowercased() { continue }
        if existing.contains(name.lowercased()) { conflicts.insert(i) }
    }
    return conflicts
}
