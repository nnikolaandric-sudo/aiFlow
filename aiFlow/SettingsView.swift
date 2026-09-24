import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Manages whether FinderFlow is registered as the system's default handler for
/// folders. This is the closest macOS allows to a "default file manager":
/// Finder itself can never be replaced (it owns the Desktop, drive mounting,
/// Open/Save dialogs and the Dock icon), but folder-open requests from the
/// `open` command, other apps, and "Open With" can be routed to FinderFlow.
enum DefaultFolderHandler {

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var bundleID: String? { Bundle.main.bundleIdentifier }

    private static let finderBundleID = "com.apple.finder"

    // macOS 26 answers paramErr (-50) to every public API that sets the
    // folder handler — NSWorkspace.setDefaultApplication(at:toOpen: .folder)
    // and LSSetDefaultRoleHandlerForContentType alike, even for Finder itself
    // (checked on 26.5.1). The toggle therefore never worked and only left
    // NSFileViewer behind. What still works is the route ForkLift and Path
    // Finder document: the per-user LSHandlers entry for public.folder
    // (LaunchServices applies it at the next login) plus NSFileViewer, which
    // applies at once and sends other apps' "Show in Finder" here.
    private static let lsDomain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
    private static let lsHandlersKey = "LSHandlers" as CFString
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    enum Status { case off, active, pendingLogin }

    /// `.active`: LaunchServices already routes folders here. `.pendingLogin`:
    /// set up, and "Show in Finder" from other apps already lands here, but
    /// folders opened by other apps switch after the next login.
    static var status: Status {
        guard let bid = bundleID else { return .off }
        if let current = NSWorkspace.shared.urlForApplication(toOpen: .folder),
           Bundle(url: current)?.bundleIdentifier == bid { return .active }
        if folderHandlerEntry() == bid || fileViewer == bid { return .pendingLogin }
        return .off
    }

    /// True when set up (active now or at the next login).
    static var isDefault: Bool { status != .off }

    /// The global NSFileViewer names this app: other apps' "Show in Finder",
    /// and our own NSWorkspace.selectFile calls, come to us.
    static var isFileViewer: Bool {
        guard let bid = bundleID, let viewer = fileViewer else { return false }
        return viewer == bid
    }

    private static var fileViewer: String? {
        CFPreferencesCopyValue("NSFileViewer" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// Register this app as the default folder handler.
    static func makeDefault(_ completion: @escaping (Error?) -> Void) {
        guard let bid = bundleID, !bid.isEmpty else {
            completion(NSError(domain: "FinderFlow",
                               code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Missing bundle identifier, can't register as default."]))
            return
        }
        _ = LSRegisterURL(bundleURL as CFURL, true)
        unregisterDevCopies(of: bid)
        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: .folder) { _ in
                DispatchQueue.main.async {
                    // Written either way: where the API works this repeats what
                    // it set; where it answers -50 (macOS 26) it is the only way.
                    setFolderHandlerEntry(bid)
                    setGlobalFileViewer(bid)
                    completion(nil)
                }
            }
            return
        }
        apply(handlerBundleID: bid, handlerURL: bundleURL, fileViewer: bid, completion: completion)
    }

    /// Restore Finder as the default folder handler.
    static func restoreFinder(_ completion: @escaping (Error?) -> Void) {
        setFolderHandlerEntry(nil)
        setGlobalFileViewer(nil)
        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: finderURL, toOpen: .folder) { _ in
                DispatchQueue.main.async { completion(nil) }
            }
            return
        }
        apply(handlerBundleID: finderBundleID, handlerURL: finderURL, fileViewer: nil, completion: completion)
    }

    private static var finderURL: URL {
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    }

    /// Bundle ID LaunchServices has on file for public.folder (per user).
    private static func folderHandlerEntry() -> String? {
        let handlers = CFPreferencesCopyValue(lsHandlersKey, lsDomain, kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [[String: Any]] ?? []
        guard let entry = handlers.first(where: { ($0["LSHandlerContentType"] as? String) == "public.folder" })
        else { return nil }
        return (entry["LSHandlerRoleAll"] ?? entry["LSHandlerRoleViewer"]) as? String
    }

    /// Replaces the public.folder entry (nil removes it; Finder is the default).
    private static func setFolderHandlerEntry(_ bundleID: String?) {
        var handlers = CFPreferencesCopyValue(lsHandlersKey, lsDomain, kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [[String: Any]] ?? []
        handlers.removeAll { ($0["LSHandlerContentType"] as? String) == "public.folder" }
        if let bundleID {
            handlers.append(["LSHandlerContentType": "public.folder",
                             "LSHandlerRoleAll": bundleID,
                             "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"]])
        }
        CFPreferencesSetValue(lsHandlersKey, handlers as CFArray, lsDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(lsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Development builds share the bundle ID; LaunchServices could hand a
    /// folder to a stale one in some build/ folder. When this copy is the
    /// installed one, those copies are unregistered (files stay untouched;
    /// launching one registers it again).
    private static func unregisterDevCopies(of bid: String) {
        guard bundleURL.path.hasPrefix("/Applications/") else { return }
        let others = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bid)
            .filter { $0.standardizedFileURL != bundleURL.standardizedFileURL }
            .filter { $0.path.contains("/build/") || $0.path.contains("/DerivedData/") || $0.path.hasPrefix("/private/") }
        guard !others.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in others {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: lsregister)
                p.arguments = ["-u", url.path]
                try? p.run()
                p.waitUntilExit()
            }
        }
    }

    private static func apply(handlerBundleID: String,
                              handlerURL: URL,
                              fileViewer: String?,
                              completion: @escaping (Error?) -> Void) {
        // Preferred path on macOS 12+: takes the app URL directly and doesn't
        // depend on the LaunchServices database already knowing our
        // CFBundleDocumentTypes claim (local builds in build/local/*.app
        // often aren't registered yet — the old LSSet... call then fails
        // with paramErr / OSStatus -50).
        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: handlerURL,
                                                     toOpen: .folder,
                                                     completion: { error in
                DispatchQueue.main.async {
                    if error == nil {
                        setGlobalFileViewer(fileViewer)
                    }
                    completion(error)
                }
            })
            return
        }
        // Legacy fallback (macOS 11): register first so LS knows we claim
        // public.folder, then set the role handler.
        // NOTE: Info.plist declares CFBundleTypeRole=Viewer, so we must ask
        // for .viewer here — .all mismatches the declaration and the system
        // rejects it with OSStatus -50 (paramErr).
        _ = LSRegisterURL(handlerURL as CFURL, true)
        // The modern NSWorkspace setter only targets a single file URL; setting the
        // default for an entire content type (every folder) still goes through
        // LaunchServices' role-handler API.
        let status = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString,
                                                           .viewer,
                                                           handlerBundleID as CFString)
        if status == noErr {
            setGlobalFileViewer(fileViewer)
            completion(nil)
        } else {
            completion(friendlyError(for: status, handlerURL: handlerURL))
        }
    }

    /// Turn a raw OSStatus into something actionable instead of
    /// "The operation couldn't be completed. (OSStatus error -50.)".
    private static func friendlyError(for status: OSStatus, handlerURL: URL) -> NSError {
        let hint: String
        if status == -50 /* paramErr */ {
            hint = "macOS rejected the change (error -50). Move aiFlow to /Applications, launch it from there, then try again. " +
                "If it still fails, run: /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f \"\(handlerURL.path)\" and retry."
        } else {
            hint = "macOS rejected the change (OSStatus error \(status))."
        }
        return NSError(domain: NSOSStatusErrorDomain,
                       code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: hint])
    }

    /// The global `NSFileViewer` preference is what some apps consult for
    /// "Reveal/Show in Finder". Passing `nil` removes the override.
    private static func setGlobalFileViewer(_ bundleID: String?) {
        let key = "NSFileViewer" as CFString
        CFPreferencesSetValue(key,
                              bundleID as CFString?,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }
}

// MARK: - Settings categories (sidebar)

/// Sidebar categories for the Settings window. Each category owns a short
/// detail pane (1–3 sections) so no single scroll holds all 13 sections.
/// The actual section views live in their own files (SettingsGeneral.swift,
/// SettingsBrowse.swift, …) — this enum is only navigation.
enum FFSettingsCategory: String, CaseIterable, Hashable {
    case general
    case browse
    case cloud
    case ai
    case mail
    case discord
    case shortcuts

    var title: String {
        switch self {
        case .general:   return "General"
        case .browse:    return "Browse"
        case .cloud:     return "Cloud"
        case .ai:        return "AI"
        case .mail:      return "Mail"
        case .discord:   return "Discord"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general:   return "gearshape.fill"
        case .browse:    return "folder.fill"
        case .cloud:     return "cloud.fill"
        case .ai:        return "sparkles"
        case .mail:      return "envelope.fill"
        case .discord:   return "paperplane.fill"
        case .shortcuts: return "keyboard.fill"
        }
    }

    /// Same visual language as FFSectionHeader, one tint per category.
    var tint: Color {
        switch self {
        case .general:   return .gray
        case .browse:    return .indigo
        case .cloud:     return .teal
        case .ai:        return FFTheme.ai
        case .mail:      return .blue
        case .discord:   return FFTheme.discord
        case .shortcuts: return .purple
        }
    }
}

/// Sidebar icon: tinted rounded square + white symbol, matching FFSectionHeader.
private struct FFSettingsCategoryIcon: View {
    let category: FFSettingsCategory

    var body: some View {
        FFTheme.controlShape
            .fill(category.tint.gradient)
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: category.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Settings window root

/// Thin shell: sidebar navigation on the left, the selected category's
/// sections on the right. Replaces the old single long Form.
struct SettingsView: View {
    /// Persisted so the window reopens on the last-visited category.
    @AppStorage("ffSettingsCategory") private var selectionRaw = FFSettingsCategory.general.rawValue

    private var selection: Binding<FFSettingsCategory?> {
        Binding(
            get: { FFSettingsCategory(rawValue: selectionRaw) },
            set: { selectionRaw = $0?.rawValue ?? FFSettingsCategory.general.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(FFSettingsCategory.allCases, id: \.self) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        FFSettingsCategoryIcon(category: category)
                    }
                    .tag(category)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            detail(for: selection.wrappedValue ?? .general)
                .navigationSplitViewColumnWidth(min: 500, ideal: 560)
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    @ViewBuilder
    private func detail(for category: FFSettingsCategory) -> some View {
        switch category {
        case .general:   GeneralSettingsDetail()
        case .browse:    BrowseSettingsDetail()
        case .cloud:     CloudSettingsDetail()
        case .ai:        AISettingsDetail()
        case .mail:      MailSettingsDetail()
        case .discord:   DiscordSettingsDetail()
        case .shortcuts: ShortcutsSettingsDetail()
        }
    }
}
