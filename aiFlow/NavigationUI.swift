import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// True while a text field / text view owns keyboard focus (inline rename,
/// search field, path-bar edit, Go-to-Folder, Settings fields…).
/// Global file shortcuts (⌘C/X/V/Z, ⌘⌫, Space) must no-op then, or typing
/// a space in a rename would open Quick Look and ⌘Z would undo files
/// instead of text.
func isEditingText() -> Bool {
    guard let win = NSApp.keyWindow, let fr = win.firstResponder else { return false }
    if fr is NSTextView { return true }
    // SwiftUI TextField is hosted in an NSTextView too, but bare NSTextField
    // (search field) reports the field itself — cover both + window fieldEditor.
    if fr is NSTextField { return true }
    if NSStringFromClass(type(of: fr)).contains("FieldEditor") { return true }
    return false
}

// MARK: - Navigation history (FinderFlow+ UI: Back / Forward)
//
// Session-only Back/Forward stacks for folder navigation, Finder-style.
// `ContentView` owns one instance and pushes every user navigation;
// programmatic back/forward pops without re-pushing (guarded by a flag).

final class NavigationHistory: ObservableObject {
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    private var current: URL?
    private let limit = 100

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Record a user-initiated navigation. Duplicate pushes are ignored and
    /// any forward history is dropped (standard browser behaviour).
    func push(_ url: URL) {
        guard current != url else { return }
        if let cur = current {
            backStack.append(cur)
            if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        }
        current = url
        forwardStack.removeAll()
    }

    /// Seed without touching the stacks (cold launch / first appear).
    func seed(_ url: URL) {
        guard current == nil else { return }
        current = url
    }

    func back() -> URL? {
        guard canGoBack, let cur = current else { return nil }
        forwardStack.append(cur)
        let prev = backStack.removeLast()
        current = prev
        return prev
    }

    func forward() -> URL? {
        guard canGoForward, let cur = current else { return nil }
        backStack.append(cur)
        let next = forwardStack.removeLast()
        current = next
        return next
    }
}

// MARK: - Go to Folder sheet (FinderFlow+ UI: ⇧⌘G)
//
// Finder's Go to Folder: type any path (with ~ and relative support),
// Tab-completion for the last component, quick picks for system locations,
// pinned and recent folders, and a clear error when the target is missing.

struct GoToFolderSheet: View {
    @Binding var currentPath: URL
    @Binding var isPresented: Bool

    @State private var text: String = ""
    @State private var error: String? = nil
    @State private var completions: [String] = []
    /// Debounce keystroke-triggered disk enumeration off the main thread.
    @State private var completionTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.heroGradient)
                        .frame(width: 30, height: 30)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Go to Folder")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Type a path. Supports ~ and Tab-completion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("/Users/…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(FFTheme.cardShape)
                .overlay(
                    FFTheme.cardShape
                        .stroke(fieldFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.25), lineWidth: fieldFocused ? 1.5 : 1)
                )
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in
                    error = nil
                    updateCompletions()
                }

            if !completions.isEmpty {
                List(completions, id: \.self) { c in
                    Button(c) {
                        text = c
                        error = nil
                        updateCompletions()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                }
                .frame(maxHeight: 120)
                .clipShape(FFTheme.cardShape)
                .overlay(
                    FFTheme.cardShape
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            if let error {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                }
                .foregroundStyle(.red)
            }

            Text("Quick picks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickPicks, id: \.path) { url in
                        Button {
                            navigate(to: url)
                        } label: {
                            Text(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.10))
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Go") { commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            text = currentPath.path
            updateCompletions()
            fieldFocused = true
        }
    }

    private var quickPicks: [URL] {
        let fm = FileManager.default
        var urls: [URL] = [
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/tmp"),
        ].compactMap { $0 }
        let pinned = (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let recent = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(4)
        urls.append(contentsOf: pinned.prefix(4))
        urls.append(contentsOf: recent)
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func expandedURL(from raw: String) -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("~") {
            s = NSString(string: s).expandingTildeInPath
        } else if !s.hasPrefix("/") {
            // Relative to the current folder, like a shell.
            s = currentPath.appendingPathComponent(s).path
        }
        return URL(fileURLWithPath: s).standardizedFileURL
    }

    private func commit() {
        let url = expandedURL(from: text)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            error = "Folder not found: \(url.path)"
            return
        }
        guard FileItem.isBrowsableFolder(url) else {
            error = "Not a browsable folder (packages open instead)."
            return
        }
        navigate(to: url)
    }

    private func navigate(to url: URL) {
        currentPath = url
        isPresented = false
    }

    /// Tab-completion style suggestions for the path being typed.
    /// Debounced + off-main: `contentsOfDirectory` + per-file stat previously
    /// ran synchronously on every keystroke on the render thread.
    private func updateCompletions() {
        completionTask?.cancel()
        let raw = text
        guard !raw.isEmpty else { completions = []; return }
        completionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let expanded = raw.hasPrefix("~")
                ? NSString(string: raw).expandingTildeInPath
                : raw
            let base: String
            let prefix: String
            if expanded.hasSuffix("/") {
                base = expanded
                prefix = ""
            } else {
                base = (expanded as NSString).deletingLastPathComponent
                prefix = (expanded as NSString).lastPathComponent.lowercased()
            }
            let names = await Task.detached(priority: .userInitiated) { () -> [String]? in
                try? FileManager.default.contentsOfDirectory(atPath: base)
            }.value
            guard !Task.isCancelled else { return }
            // Invalid base path: clear instead of leaving the previous
            // text's suggestions on screen (the old code returned silently).
            guard let names else {
                if raw == text { completions = [] }
                return
            }
            let matches = names
                .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) }
                .sorted()
                .prefix(8)
                .map { name -> String in
                    let full = (base as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                    return isDir.boolValue ? full + "/" : full
                }
            guard !Task.isCancelled, raw == text else { return }
            completions = Array(matches)
        }
    }
}

// MARK: - Row density (Comfortable / Compact)
//
// One environment flag, set once in ContentView from @AppStorage, read by row
// views (list / columns / icons / sidebar / section headers). Environment
// invalidation bypasses .equatable() skips, so no row signatures change.

private struct CompactRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ffCompactRows: Bool {
        get { self[CompactRowsKey.self] }
        set { self[CompactRowsKey.self] = newValue }
    }
}

// MARK: - FFTheme (moderan dizajn sistem)
//
// Brand indigo (#2D52E0, dark #7E9BFF) dolazi iz AccentColor asseta pa
// `Color.accentColor` svuda automatski vuče brand. Ovi tokeni dodaju
// gradijente, pill/badge i kartice na vrh sistemskog accent-a —
// poštuju i light i dark mode jer se grade iz accentColor-a.

enum FFTheme {
    /// Hero gradijent: brand indigo → ljubičasta (selekcija, hero krugovi).
    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color(red: 0.49, green: 0.36, blue: 1.0)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
    /// Suptilan gradijent za pill/circle pozadine (empty states).
    static var softGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), Color(red: 0.49, green: 0.36, blue: 1.0).opacity(0.10)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
    /// Aktivna toolbar pill pozadina.
    static var activePill: Color { Color.accentColor.opacity(0.14) }
    /// Badge pozadina + border.
    static var badgeBG: Color { Color.accentColor.opacity(0.12) }
    static var badgeBorder: Color { Color.accentColor.opacity(0.28) }
    /// Hover za ikon dugmad.
    static var hoverBG: Color { Color.primary.opacity(0.07) }
    /// Discord blurple (brand prepoznatljivost, čitljiv i u dark mode-u).
    static var discord: Color { Color(red: 0.345, green: 0.396, blue: 0.949) }
    static var discordGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.345, green: 0.396, blue: 0.949),
                     Color(red: 0.55, green: 0.45, blue: 1.0)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
    /// Boja vrste fajla za Kind bedževe — prigušene sistemske boje,
    /// dovoljno žive da se tip prepozna na prvi pogled.
    ///
    /// Tip se određuje preko UTType-a iz ekstenzije, ne po tekstu opisa:
    /// `localizedTypeDescription` na ovom macOS-u vraća „PNG File" i „MP3 File",
    /// pa je traženje riječi „image"/„audio" promašivalo sve osim PDF-a i ZIP-a
    /// (a na drugom jeziku sistema promašilo bi i njih). Tekst opisa ostaje kao
    /// rezerva za fajlove bez ekstenzije.
    static func kindColor(kind: String, ext: String = "", isDirectory: Bool, isArchive: Bool) -> Color {
        if isDirectory { return .blue }
        if isArchive { return .orange }

        if !ext.isEmpty, let t = UTType(filenameExtension: ext) {
            // Arhive namjerno ne idu preko `.archive` konformanse: .docx/.xlsx
            // se svode na public.zip-archive pa bi Word fajl bio narandžast.
            // Za arhive je mjerodavan ArchiveService (isArchive gore).
            if t.conforms(to: .pdf)        { return .red }
            if t.conforms(to: .image)      { return .green }
            if t.conforms(to: .audio)      { return .pink }
            if t.conforms(to: .movie) || t.conforms(to: .video) { return .purple }
            if t.conforms(to: .diskImage)  { return .orange }
            if t.conforms(to: .sourceCode) || t.conforms(to: .script)
                || t.conforms(to: .json) || t.conforms(to: .xml)
                || t.conforms(to: .html) || t.conforms(to: .propertyList) { return .teal }
            if t.conforms(to: .application) || t.conforms(to: .unixExecutable) { return .indigo }
        }

        let k = kind.lowercased()
        if k.contains("disk image") || k.contains("archive") || k.contains("zip") || k.contains("compressed") { return .orange }
        if k.contains("pdf") { return .red }
        if k.contains("image") || k.contains("picture") || k.contains("photo") { return .green }
        if k.contains("audio") || k.contains("music") || k.contains("sound") { return .pink }
        if k.contains("movie") || k.contains("video") || k.contains("film") { return .purple }
        return .secondary
    }

    /// AI ljubičasta — isti ton kojim se hero gradijent završava, da sve što
    /// je AI (Organizer, ✨ dugme, sekcija u Settings) ima jednu boju.
    static var ai: Color { Color(red: 0.49, green: 0.36, blue: 1.0) }
    static var aiGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.55, green: 0.42, blue: 1.0),
                     Color(red: 0.40, green: 0.26, blue: 0.95)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Semafor slobodnog prostora: zeleno dok ima mesta, narandžasto ispod
    /// 15%, crveno ispod 5% — isti pragovi koje macOS koristi za upozorenja.
    static func freeSpaceColor(fraction: Double) -> Color {
        if fraction < 0.05 { return .red }
        if fraction < 0.15 { return .orange }
        return .green
    }

    // MARK: Radijusi
    //
    // Audit je zatekao 4/5/6/7/8/10/14/16 izmešano po fajlovima. Ova skala ima
    // četiri koraka i svaki element bira korak po ulozi, ne po osećaju.
    /// Mini oznake (keycap „⌘F").
    static let rTiny: CGFloat = 4
    /// Kontrole: hover pilule, ikon dugmad, redovi liste, tabovi editora.
    static let rControl: CGFloat = 6
    /// Kartice, polja, paneli, liste.
    static let rCard: CGFloat = 10
    /// Plutajući slojevi: toast, akcijski bar nad sadržajem.
    static let rFloating: CGFloat = 16

    // Gotovi oblici — `.continuous` je svuda isti, pa se ne zaboravi.
    static var tinyShape:     RoundedRectangle { RoundedRectangle(cornerRadius: rTiny,     style: .continuous) }
    static var controlShape:  RoundedRectangle { RoundedRectangle(cornerRadius: rControl,  style: .continuous) }
    static var cardShape:     RoundedRectangle { RoundedRectangle(cornerRadius: rCard,     style: .continuous) }
    static var floatingShape: RoundedRectangle { RoundedRectangle(cornerRadius: rFloating, style: .continuous) }
}

extension View {
    /// Moderan pill badge: accent tint + tanak accent border.
    func ffBadge() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(FFTheme.badgeBG)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(FFTheme.badgeBorder, lineWidth: 0.75))
    }
    /// Aktivna toolbar ikonica: accent pill iza ikonice.
    func ffActivePill(_ active: Bool) -> some View {
        self.background(
            FFTheme.controlShape
                .fill(active ? FFTheme.activePill : Color.clear)
        )
    }
}

// MARK: - Kind bedž
//
// Vrsta fajla je bila siv tekst u tri preview kartice (sidebar preview,
// online-only placeholder, Columns preview) — na prvi pogled se nije videlo
// da li gledaš PDF, sliku ili arhivu. Bedž uzima boju iz FFTheme.kindColor,
// pa je tip prepoznatljiv bez čitanja.

struct FFKindBadge: View {
    let item: FileItem

    var body: some View {
        let tint = FFTheme.kindColor(kind: item.kind,
                                     ext: item.fileExtension,
                                     isDirectory: item.isDirectory && !item.isPackage,
                                     isArchive: item.isArchive)
        Text(item.kind.isEmpty ? "Unknown" : item.kind)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.75))
            .help(item.kind)
    }
}

/// Red „Kind:" u preview karticama — ista širina labele kao ostali redovi,
/// vrednost je bedž u boji.
struct FFKindRow: View {
    let item: FileItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Kind:").font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            FFKindBadge(item: item)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Obojen header sekcije (Settings)
//
// Svi headeri su bili jednako sivi, pa se duga Settings lista čitala kao jedan
// blok. Ikonica u obojenom kvadratiću (kao System Settings) daje svakoj sekciji
// svoju tačku za oko; tekst ostaje sistemski da Form zadrži svoj izgled.

// MARK: - Keycap + jedno prazno stanje za preview površine
//
// Tri preview površine (glavni preview panel, Columns hint, Columns preview
// pane) crtale su svaka svoje prazno stanje: tri teksta, dvije veličine kruga
// i tri različite ikone — a jedna od njih, „doc.magnifyingglass", ne postoji u
// SF Symbols, pa je krug u glavnom panelu bio prazan mjehur (provjereno
// snimkom prozora i `NSImage(systemSymbolName:)`). Jedna komponenta rješava i
// nedosljednost i tu grešku.

/// Mini tipka za savjete („Space", „⌘F") — isti stil kao ⌘F u polju pretrage.
struct FFKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(FFTheme.tinyShape.fill(Color.primary.opacity(0.05)))
            .overlay(FFTheme.tinyShape.strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

/// Prazno stanje preview površine: ikona u mekom krugu, naslov, objašnjenje i
/// (opcioni) tipkovni savjet.
struct FFEmptyPreview: View {
    var symbol: String = "eye"
    let title: String
    var message: String? = nil
    /// Savjet ispod teksta, npr. („Space", „Quick Look").
    var hint: (key: String, text: String)? = nil
    /// Uži razmaci za tijesne površine (Columns hint pored zadnje kolone).
    var compact: Bool = false

    private var diameter: CGFloat { compact ? 52 : 60 }

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            ZStack {
                Circle()
                    .fill(FFTheme.softGradient)
                    .frame(width: diameter, height: diameter)
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
                    .frame(width: diameter, height: diameter)
                Image(systemName: symbol)
                    .font(.system(size: compact ? 19 : 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint {
                HStack(spacing: 5) {
                    FFKeycap(key: hint.key)
                    Text(hint.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Čitljiva lokacija za rezultate pretrage. Rezultati su prije pokazivali punu
/// apsolutnu putanju roditelja, pa je svaki red imao isti stometarski tekst
/// („/private/tmp/claude-501/-Users-…/data/Mix") koji je pojeo cijelu širinu i
/// ništa nije razlikovao. Unutar foldera u kojem se traži vraća relativnu
/// putanju, van njega stazu sa `~`.
func ffDisplayLocation(of url: URL, relativeTo root: URL?) -> String {
    let parent = url.deletingLastPathComponent()
    if let root {
        let rootPath = root.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if parentPath == rootPath { return root.lastPathComponent }
        if parentPath.hasPrefix(rootPath + "/") {
            let rel = parentPath.dropFirst(rootPath.count + 1)
            return root.lastPathComponent + "/" + rel
        }
    }
    return (parent.path as NSString).abbreviatingWithTildeInPath
}

/// Lokacija pogotka za red rezultata — nil kad pogodak leži baš u folderu u
/// kojem se traži. Bez toga bi kod pretrage „u ovom folderu" svaki red nosio
/// isto ime foldera, tj. nula informacije po redu.
func ffSearchLocation(of url: URL, relativeTo root: URL?) -> String? {
    if let root,
       url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path {
        return nil
    }
    return ffDisplayLocation(of: url, relativeTo: root)
}

// MARK: - Red „Size" sa detaljima medija
//
// Uz veličinu fajla preview kartica sad kaže i ono što Finder pokazuje:
// dimenzije slike, broj strana PDF-a, trajanje audio/video zapisa
// („13 KB · 1600 × 1000", „209 KB · 3 pages", „3,4 MB · 3:25"). Čita se samo
// zaglavlje, van glavne niti, tek za fajl koji je selektovan — i nikad za
// fajl koji je samo na mreži (čitanje bi pokrenulo preuzimanje).

struct FFSizeRow: View {
    let item: FileItem
    /// Već formatirana veličina — svaka kartica zadržava svoj format.
    let size: String
    @State private var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("Size:").font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(detail.map { size + " · " + $0 } ?? size)
                .font(.caption)
                .lineLimit(2)
        }
        .task(id: item.url) {
            detail = nil
            guard !item.isDirectory else { return }
            let found = await FFMediaInfo.summary(for: item.url)
            if !Task.isCancelled { detail = found }
        }
    }
}

enum FFMediaInfo {
    /// „1600 × 1000", „3 pages", „3:25" — ili nil kad nema šta da se kaže.
    static func summary(for url: URL) async -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        let isMedia = type.conforms(to: .audiovisualContent)
        guard isMedia || type.conforms(to: .image) || type.conforms(to: .pdf) else { return nil }
        let local = await Task.detached(priority: .utility) { !FileItem.isNotDownloaded(url) }.value
        guard local, !Task.isCancelled else { return nil }

        if isMedia {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.isNumeric, duration.seconds >= 1 else { return nil }
            return durationText(duration.seconds)
        }
        return await Task.detached(priority: .utility) { () -> String? in
            if type.conforms(to: .pdf) {
                guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return nil }
                return doc.numberOfPages == 1 ? "1 page" : "\(doc.numberOfPages) pages"
            }
            // Slika: samo zaglavlje (bez dekodiranja piksela).
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(w) × \(h)"
        }.value
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Preview split (lista + desni preview sa ručicom)
//
// Desni preview je imao liniju koja je pokazivala kursor za širenje, ali se
// nije dala pomjeriti (vidi ResizeHandle u ColumnsView.swift za uzrok). Ovdje
// žive ručica, granice i zapamćena širina, a ContentView samo kaže šta je
// lista, a šta preview:
//   • širina se tokom vuče drži u @State ovog view-a — ContentView se ne
//     evaluira ~60 puta u sekundi, lista lijevo samo dobija novu širinu;
//   • u postavke („ffPreviewWidth", isti ključ kao ranije) upisuje se jednom,
//     kad korisnik pusti ručicu;
//   • granice prate prozor: lista uvijek zadrži bar `minMain`, pa se pri
//     suženju prozora preview privremeno sabije, a zapamćena širina ostaje
//     i vrati se kad prozor opet naraste;
//   • dvoklik na ručicu vraća podrazumijevanu širinu.

struct PreviewSplit<Main: View, Preview: View>: View {
    let showsPreview: Bool
    let main: Main
    let preview: Preview

    init(showsPreview: Bool,
         @ViewBuilder main: () -> Main,
         @ViewBuilder preview: () -> Preview) {
        self.showsPreview = showsPreview
        self.main = main()
        self.preview = preview()
    }

    static var defaultWidth: Double { 260 }
    static var minPreview: Double { 180 }
    /// Lista lijevo nikad uže od ovoga.
    static var minMain: Double { 260 }
    /// Gornja granica i na velikom ekranu — preko toga je lista premala.
    static var maxPreview: Double { 900 }
    /// Ispod ove širine kontejnera preview se auto-sakriva da lista
    /// (posebno Name kolona) ne bi bila sabijena van ekrana.
    static var collapseThreshold: Double { 560 }

    @AppStorage("ffPreviewWidth") private var storedWidth: Double = 260
    @State private var liveWidth: Double?
    @State private var dragStartWidth: Double = 260
    @State private var containerWidth: Double = 0

    /// Najšire što preview smije biti u trenutnom prozoru (8 = ručica).
    /// Nikad više od pola prozora: širina povučena na velikom ekranu je na
    /// manjem prozoru sabijala listu na trećinu (imena „Whats…ned).pdf",
    /// odsječen datum). Zapamćena širina ostaje i vraća se kad ima mjesta.
    private var upperBound: Double {
        guard containerWidth > 0 else { return Self.maxPreview }
        let half = (containerWidth - 8) * 0.5
        return max(Self.minPreview, min(Self.maxPreview, half, containerWidth - Self.minMain - 8))
    }

    private func clamp(_ width: Double) -> Double {
        min(upperBound, max(Self.minPreview, width))
    }

    /// Uski prozor: preview se privremeno skloni (zapamćena širina ostaje).
    private var effectiveShowsPreview: Bool {
        guard showsPreview else { return false }
        guard containerWidth > 0 else { return true }
        return containerWidth >= Self.collapseThreshold
    }

    var body: some View {
        HStack(spacing: 0) {
            main
                .frame(minWidth: Self.minMain)
            if effectiveShowsPreview {
                HStack(spacing: 0) {
                    ResizeHandle(
                        onDrag: { _ in },
                        onBegan: { dragStartWidth = clamp(storedWidth) },
                        // Ručica je lijevo od panela: vuča ulijevo (−) ga širi.
                        onTotal: { total in liveWidth = clamp(dragStartWidth - Double(total)) },
                        onEnded: {
                            if let w = liveWidth { storedWidth = w.rounded() }
                            liveWidth = nil
                        },
                        onDoubleClick: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                storedWidth = Self.defaultWidth
                            }
                        }
                    )
                    preview
                        .frame(width: liveWidth ?? clamp(storedWidth))
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: effectiveShowsPreview)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
            containerWidth = width
        }
    }
}

struct FFSectionHeader: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 7) {
            FFTheme.controlShape
                .fill(tint.gradient)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(title)
        }
    }
}
