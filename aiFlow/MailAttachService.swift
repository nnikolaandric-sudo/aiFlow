import AppKit
import SwiftUI
import Combine
import ApplicationServices
import Carbon
import Security

// MARK: - Mail Attach from FinderFlow (⌥⌘A)
//
// Zaobilazi sistemski Attach dialog (NSOpenPanel je od macOS 10.15 uvek u
// zasebnom Powerbox procesu i ne moze da se zameni): globalni picker nad
// svime, Enter -> attach u trenutno otvoreni Mail compose.
//
// Dva puta ubacivanja:
//  1. AppleScript u front outgoing message (najcistije, ne dira fokus tela).
//  2. Fallback: file URL-ovi na pasteboard + Cmd-V (isti mehanizam kao
//     "Copy to Attach in Mail").
// Oba traze da je FinderFlow pokrenut; (2) i Open-panel asistent traze
// Accessibility dozvolu (CGEvent keystroke).

enum MailAttachPrefs {    static let enabledKey   = "ffMailAttachEnabled"
    static let recentKey    = "ffMailAttachShowRecent"
    static let favKey       = "ffMailAttachShowFavorites"
    static let searchKey    = "ffMailAttachShowSearch"
    static let assistantKey = "ffMailAttachAssistantEnabled"
    static let recentFilesKey = "ffMailAttachRecentFiles"
    static let maxRecent = 20

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    static var showRecent: Bool {
        UserDefaults.standard.object(forKey: recentKey) as? Bool ?? true
    }
    static var showFavorites: Bool {
        UserDefaults.standard.object(forKey: favKey) as? Bool ?? true
    }
    static var showSearch: Bool {
        UserDefaults.standard.object(forKey: searchKey) as? Bool ?? true
    }
    static var assistantEnabled: Bool {
        UserDefaults.standard.object(forKey: assistantKey) as? Bool ?? true
    }

    static func recentFiles() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func record(_ urls: [URL]) {
        var paths = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        for u in urls {
            paths.removeAll { $0 == u.path }
            paths.insert(u.path, at: 0)
        }
        UserDefaults.standard.set(Array(paths.prefix(maxRecent)), forKey: recentFilesKey)
    }
}

/// Dijagnosticki log u fajl (vidljiv bez Console.app):
/// ~/Library/Logs/FinderFlow-diag.log — svaki hotkey, picker i attach
/// upise red sa pravim rezultatom.
enum MailAttachDiag {
    static func log(_ s: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FinderFlow-diag.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            try? h.seekToEndOfFile()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
        NSLog("FinderFlow: %@", s)
    }
}

final class MailAttachService: ObservableObject {
    static let shared = MailAttachService()

    @Published var lastMessage: String?
    @Published var lastError: String?
    /// True kad je sistemski ⌥⌘A hotkey uspesno registrovan (vidi Settings).
    @Published var hotkeyActive = false
    /// Rezultat poslednje provere Mail scripting dozvole (Settings dugme).
    @Published var probeResult: String?

    private var localMonitor: Any?
    private var notifObserver: NSObjectProtocol?
    private var carbonHotKey: EventHotKeyRef?
    private var started = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        stopMonitors()
        notifObserver = NotificationCenter.default.addObserver(
            forName: .ffAttachFromFinderFlow, object: nil, queue: .main) { [weak self] _ in
                self?.openPicker()
            }
        NotificationCenter.default.addObserver(
            forName: .ffShowPanelAssistant, object: nil, queue: .main) { [weak self] _ in
                self?.openAssistant()
            }
        // Lokalno (FinderFlow frontmost): progutaj ⌥⌘A da ne ode dalje.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, MailAttachPrefs.isEnabled else { return event }
            if Self.isAttachHotkey(event) && !event.isARepeat {
                self.openPicker()
                return nil
            }
            return event
        }
        // Globalno pokriva Carbon hotkey ispod (bez ikakvih dozvola).
        // Namerno BEZ NSEvent.addGlobalMonitorForEvents: on trazi
        // Input Monitoring dozvolu i macOS ponovo pita posle svakog
        // rebuilda ad-hoc builda — a za ⌥⌘A nam uopste ne treba.
        registerCarbonHotkey()
        // Prvi ⌥⌘A posle pokretanja: hladni SwiftUI + Quick Look = ~650 ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if MailAttachPrefs.isEnabled { MailAttachWindowManager.shared.prewarm() }
        }
    }

    func stop() {
        started = false
        stopMonitors()
        if let o = notifObserver { NotificationCenter.default.removeObserver(o); notifObserver = nil }
    }

    private func stopMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        unregisterCarbonHotkey()
    }

    // MARK: Carbon sistemski hotkey (bez dozvola)

    private func registerCarbonHotkey() {
        unregisterCarbonHotkey()
        let hkID = EventHotKeyID(signature: OSType(0x46464154), id: 1) // 'FFAT'
        let mods = UInt32(cmdKey | optionKey)
        // kVK_ANSI_A == 0
        let status = RegisterEventHotKey(0, mods, hkID, GetApplicationEventTarget(), 0, &carbonHotKey)
        guard status == noErr else {
            NSLog("FinderFlow: RegisterEventHotKey failed (%d)", status)
            return
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                if MailAttachPrefs.isEnabled { MailAttachService.shared.openPicker() }
            }
            return noErr
        }
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
        if installStatus == noErr {
            hotkeyActive = true
            MailAttachDiag.log("hotkey registered axtrust=\(AXIsProcessTrusted()) signedDev=\(FFSigningIdentity.appIsSignedWithIt())")
        } else {
            hotkeyActive = false
            MailAttachDiag.log("InstallEventHandler failed (\(installStatus))")
        }
    }

    private func unregisterCarbonHotkey() {
        if let hk = carbonHotKey { UnregisterEventHotKey(hk); carbonHotKey = nil }
        hotkeyActive = false
    }

    static func isAttachHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags == [.command, .option] else { return false }
        // keyCode 0 == fizicki taster A (radi i na non-US rasporedima gde
        // charactersIgnoringModifiers vrati "å" ili sl.); characters kao backup.
        if event.keyCode == 0 { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "a"
    }

    // MARK: - Picker

    func openPicker() {
        guard MailAttachPrefs.isEnabled else { return }
        MailAttachDiag.log("picker opened")
        MailAttachWindowManager.shared.open()
    }

    func openAssistant() {
        guard MailAttachPrefs.assistantEnabled else {
            lastError = "aiFlow Assistant je iskljucen (Settings → Mail integration)."
            return
        }
        MailPanelAssistantWindowManager.shared.open()
    }

    // MARK: - Attach

    /// Glavni ulaz iz pickera: proba AppleScript, pa pasteboard + Cmd-V.
    @discardableResult
    func attach(_ urls: [URL]) -> Bool {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            lastError = "Fajl vise ne postoji."
            return false
        }
        MailAttachPrefs.record(files)
        // Pasteboard uvek napuni — rucni ⌘V u Mailu radi i bez dozvola.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files as [NSURL])

        // OBAVEZNO zatvori picker PRE AppleScript/Cmd-V: sistemski consent
        // prozor (Allow/Don't Allow) inace ostane ISPOD naseg floating
        // panela pa ga korisnik nikad ne vidi — a bez klika na Allow nema
        // ni Automation entry-ja ni attacha. Isto vazi za Cmd-V fallback
        // koji sme samo kad je Mail napred.
        MailAttachWindowManager.shared.close()

        // Sa Accessibility prvo fokusirana poruka (ona koju korisnik gleda);
        // AppleScript vidi samo poruke koje je skripta napravila i vrati
        // bilo koju od njih, ne onu napred.
        if pasteIntoOpenCompose() {
            MailAttachDiag.log("attach files=\(files.map(\.lastPathComponent)) via=AX")
            lastMessage = files.count == 1
                ? "Attached \(files[0].lastPathComponent) to the open message"
                : "Attached \(files.count) files to the open message"
            lastError = nil
            return true
        }

        let res = appleScriptAttachResult(files)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        MailAttachDiag.log("attach files=\(files.map(\.lastPathComponent)) res=\(res) front=\(front) axtrust=\(accessibilityTrusted())")
        // -1743 se moze sakriti unutar ERR_* (script-try ga uhvati) —
        // to je i dalje Automation problem, ne Mail problem.
        if res.contains("-1743") {
            lastError = "aiFlow nema dozvolu da kontrolise Mail. Otvorite System Settings → Privacy & Security → Automation → aiFlow → Mail (ukljucite), pa Enter opet. Ako aiFlow nije u listi: dugme \"Check Mail permission\" u Settingsu izazove Allow prozor."
            return false
        }
        switch res {
        case "OK":
            lastMessage = files.count == 1
                ? "Attached \(files[0].lastPathComponent) to Mail"
                : "Attached \(files.count) files to Mail"
            lastError = nil
            return true
        default:
            // "OK:<subject>" — uspeh uz naziv poruke da se vidi GDE je zavrsilo.
            if res.hasPrefix("OK:") {
                let subj = String(res.dropFirst(3))
                lastMessage = files.count == 1
                    ? "Attached \(files[0].lastPathComponent) to “\(subj)”"
                    : "Attached \(files.count) files to “\(subj)”"
                lastError = nil
                return true
            }
            // "NO_COMPOSE_0" — Mail `outgoing messages` sadrzi samo poruke
            // koje je napravio AppleScript; ⌘N/Reply prozori se tu nikad ne
            // pojave. Otvori novu poruku sa prilogom (samo Automation).
            if res.hasPrefix("NO_COMPOSE_0") {
                let created = appleScriptNewMessageResult(files)
                MailAttachDiag.log("new message res=\(created)")
                if created == "NEW" {
                    lastMessage = files.count == 1
                        ? "Opened new Mail message with \(files[0].lastPathComponent)"
                        : "Opened new Mail message with \(files.count) files"
                    lastError = nil
                    return true
                }
                lastError = "Mail nije prihvatio novu poruku (\(created)). Fajl je kopiran — u Mailu pritisnite ⌘V."
                return false
            }
            // Script puta nije uspeo iz Mail razloga — probaj automatski
            // Cmd-V u Mail (sintetizovan, nikakvo rucno lepljenje).
            // Picker je vec zatvoren; dovedi Mail napred pa proveri.
            activateMail()
            Thread.sleep(forTimeInterval: 0.4)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail",
               pasteIntoMailViaKeystroke() { return true }
            if res.hasPrefix("ERR_ATTACH") {
                lastError = "Compose je otvoren ali ubacivanje nije uspelo (\(res)). Ukucajte rec u telo pa Enter opet."
            } else {
                lastError = "Mail nije dao pristup poruci (\(res)). Prepisite mi ovaj kod."
            }
            return false
        }
    }

    // MARK: - Provera Mail dozvole (Settings dugme)

    /// Provera prave Automation dozvole. `get version` NIJE validan test —
    /// odgovara ga Launch Services iz Info.plist-a bez Apple Eventa ka Mailu
    /// (lažni OK pa attach opet -1743). Ovde saljemo stvaran event koji
    /// zahteva kontrolu nad Mailom.
    func probeMailScripting() {
        MailAttachWindowManager.shared.close()
        Thread.sleep(forTimeInterval: 0.3)
        let src = "tell application \"Mail\" to get name of first mailbox of account 1"
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        let num = err?["NSAppleScriptErrorNumber"] as? Int
        if let s = result?.stringValue, !s.isEmpty {
            probeResult = "Mail scripting: OK (\(s))"
            MailAttachDiag.log("probe OK control \(s)")
            lastError = nil
        } else if num == -1743 || num == -1728 {
            // -1728: event stigao ali nema account 1 (prazan nalog) — to znači
            // da je Automation prošao. -1743: još uvek blokirano.
            if num == -1728 {
                probeResult = "Mail scripting: OK (no account — Apple Event delivered)"
                MailAttachDiag.log("probe OK via -1728 (event delivered, no account)")
                lastError = nil
            } else {
                probeResult = "Mail scripting: blokirano (-1743). Kliknite Allow u sistemskom prozoru, pa ponovo."
                MailAttachDiag.log("probe blocked -1743")
            }
        } else {
            probeResult = "Mail scripting: greška (\(num ?? -1)). Probajte opet."
            MailAttachDiag.log("probe error \(num ?? -1)")
        }
    }

    /// Kopiraj bez automatike (ista semantika kao postojeci copyFilesForMailAttach).
    func copyForManualPaste(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        MailAttachPrefs.record(files)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        lastMessage = files.count == 1
            ? "Copied — paste in Mail with ⌘V"
            : "Copied \(files.count) files — paste in Mail with ⌘V"
    }

    // MARK: AppleScript — front outgoing message

    /// Vraca "OK" | "NO_COMPOSE" | "FAIL". Svaki Enter pokusava ponovo:
    /// macOS pita za Automation dozvolu samo dok je status "undecided",
    /// pa allow-then-retry radi — nista se ne kesira.
    private func appleScriptAttachResult(_ files: [URL]) -> String {
        guard !files.contains(where: { containsAppleScriptUnsafeChars($0.path) }) else { return "FAIL" }
        let literals = files.map { appleScriptStringLiteral($0.path) }
        let makes = literals.map {
            "make new attachment with properties {file name:(POSIX file \($0) as alias)} at after last paragraph"
        }.joined(separator: "\n")
        let src = """
        tell application "Mail"
            activate
            try
                set visList to every outgoing message whose visible is true
            on error errMsg number errNum
                return "ERR_VIS " & errNum & " " & errMsg
            end try
            try
                set allList to every outgoing message
            on error errMsg number errNum
                set allList to {}
            end try
            if (count of visList) = 0 then
                return "NO_COMPOSE_0 vis=0 all=" & (count of allList)
            end if
            try
                set theMessage to item 1 of visList
            on error errMsg number errNum
                return "ERR_REF " & errNum & " " & errMsg
            end try
            try
                tell content of theMessage
        \(makes)
                end tell
            on error errMsg number errNum
                return "ERR_ATTACH " & errNum & " " & errMsg
            end try
            try
                return "OK:" & (subject of theMessage)
            on error
                return "OK"
            end try
        end tell
        """
        var err: NSDictionary?
        let script = NSAppleScript(source: src)
        let result = script?.executeAndReturnError(&err)
        if let s = result?.stringValue, !s.isEmpty { return s }
        // -1743 (errAEEventNotPermitted): Automation odbijen ili prompt
        // odbacen — sledeci Enter pokusava opet, macOS pita samo jednom.
        if (err?["NSAppleScriptErrorNumber"] as? Int) == -1743 {
            lastError = "aiFlow nema dozvolu da kontrolise Mail. Otvorite System Settings → Privacy & Security → Automation → aiFlow → Mail (ukljucite), pa pritisnite Enter opet."
        }
        return "FAIL"
    }

    /// "NEW" | "ERR_NEW ..." | "FAIL".
    private func appleScriptNewMessageResult(_ files: [URL]) -> String {
        guard !files.contains(where: { containsAppleScriptUnsafeChars($0.path) }) else { return "FAIL" }
        let makes = files.map {
            "make new attachment with properties {file name:(POSIX file \(appleScriptStringLiteral($0.path)) as alias)} at after last paragraph"
        }.joined(separator: "\n")
        let src = """
        tell application "Mail"
            activate
            try
                set theMessage to make new outgoing message with properties {visible:true}
                delay 0.3
                tell content of theMessage
        \(makes)
                end tell
            on error errMsg number errNum
                return "ERR_NEW " & errNum & " " & errMsg
            end try
            return "NEW"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let s = result?.stringValue, !s.isEmpty { return s }
        return "FAIL \((err?["NSAppleScriptErrorNumber"] as? Int) ?? 0)"
    }

    // MARK: Otvorena poruka preko Accessibility

    /// Mail ne izlaze ⌘N/Reply poruke AppleScriptu, pa: prvi Mail prozor
    /// (spreda ka nazad) koji ima telo (AXWebArea) a nema listu poruka
    /// (AXTable/AXOutline) je compose — kursor u telo pa ⌘V. Pasteboard vec
    /// drzi fajlove. Bez tela nista ne salje (⌘V u To: bi nalepio putanju).
    private func pasteIntoOpenCompose() -> Bool {
        guard accessibilityTrusted(),
              let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first
        else { return false }
        let app = AXUIElementCreateApplication(mail.processIdentifier)
        // AX vidi samo prozore sa trenutnog Space-a; kad je Mail fullscreen,
        // prelaz na njegov Space traje — sacekaj da se prozori pojave.
        mail.activate()
        var windows: [AXUIElement] = []
        for _ in 0..<14 {
            windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if !windows.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        // Fokusiran prozor prvi — to je poruka na kojoj korisnik radi.
        if let focused = axValue(app, kAXFocusedWindowAttribute) {
            let f = focused as! AXUIElement
            windows.removeAll { CFEqual($0, f) }
            windows.insert(f, at: 0)
        }
        for window in windows {
            var budget = 4000
            var hasList = false
            var body: AXUIElement?
            scanForBody(window, depth: 0, budget: &budget, hasList: &hasList, body: &body)
            guard let body, !hasList else { continue }
            let title = axValue(window, kAXTitleAttribute) as? String ?? ""
            mail.activate()
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.4)
            // Kursor vec u telu (korisnik kuca) → lepi tamo gde jeste; inace
            // fokus na telo (to ga stavi na pocetak poruke).
            let caretInBody = focusedElement(of: app, isInside: body)
            let focus: AXError = caretInBody ? .success
                : AXUIElementSetAttributeValue(body, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            MailAttachDiag.log("open compose [\(title)] caretInBody=\(caretInBody) focus=\(focus.rawValue) front=\(front ?? "none")")
            guard focus == .success, front == "com.apple.mail" else { return false }
            Thread.sleep(forTimeInterval: 0.15)
            return sendKeystroke(keyCode: 9, flags: .maskCommand) // V
        }
        MailAttachDiag.log("open compose: none found in \(windows.count) windows")
        dumpAXTree(windows)
        return false
    }

    /// Dijagnostika: struktura Mail prozora u ~/Library/Logs/FinderFlow-ax-dump.txt.
    private func dumpAXTree(_ windows: [AXUIElement]) {
        var out = "\(Date())\n"
        var lines = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 18, lines < 1500 else { return }
            lines += 1
            let role = axValue(e, kAXRoleAttribute) as? String ?? "?"
            let sub = axValue(e, kAXSubroleAttribute) as? String ?? ""
            let title = (axValue(e, kAXTitleAttribute) as? String ?? "").prefix(40)
            let desc = (axValue(e, kAXDescriptionAttribute) as? String ?? "").prefix(40)
            let ident = axValue(e, "AXIdentifier") as? String ?? ""
            out += String(repeating: " ", count: depth * 2) + "\(role) \(sub) t=[\(title)] d=[\(desc)] id=[\(ident)]\n"
            for c in axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        for w in windows { walk(w, 0); out += "-----\n" }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FinderFlow-ax-dump.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private func focusedElement(of app: AXUIElement, isInside container: AXUIElement) -> Bool {
        guard let focused = axValue(app, kAXFocusedUIElementAttribute) else { return false }
        var e = focused as! AXUIElement
        for _ in 0..<40 {
            if CFEqual(e, container) { return true }
            guard let parent = axValue(e, kAXParentAttribute) else { return false }
            e = parent as! AXUIElement
        }
        return false
    }

    private func scanForBody(_ e: AXUIElement, depth: Int, budget: inout Int,
                             hasList: inout Bool, body: inout AXUIElement?) {
        guard depth < 14, budget > 0, !hasList else { return }
        budget -= 1
        switch axValue(e, kAXRoleAttribute) as? String {
        case "AXTable", "AXOutline":
            hasList = true
            return
        case "AXWebArea":
            if body == nil { body = e }
            return
        default:
            break
        }
        for child in axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            scanForBody(child, depth: depth + 1, budget: &budget, hasList: &hasList, body: &body)
        }
    }

    private func axValue(_ e: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    // MARK: Fallback — Cmd-V keystroke

    /// Aktivira Mail i salje Cmd-V. Vraca false kad nema Accessibility dozvole.
    @discardableResult
    func pasteIntoMailViaKeystroke() -> Bool {
        guard accessibilityTrusted() else {
            lastError = "Za automatsko lepljenje ukljucite aiFlow pod System Settings → Privacy & Security → Accessibility."
            return false
        }
        activateMail()
        // Daj Mailu momenat da izadje napred pre Cmd-V.
        Thread.sleep(forTimeInterval: 0.35)
        guard sendKeystroke(keyCode: 9, flags: .maskCommand) else { return false } // V
        lastMessage = "Attached to Mail"
        lastError = nil
        return true
    }

    // MARK: Open/Save assistant — voznja sistemskog dijaloga

    /// Odvede otvoreni NSOpenPanel na folder fajla: ⇧⌘G, paste path, Enter,
    /// pa Enter za potvrdu. Radi i za Mail Attach dialog i za bilo koji Open.
    func driveOpenPanel(to url: URL) {
        guard accessibilityTrusted() else {
            lastError = "Za voznju dijaloga ukljucite aiFlow pod System Settings → Privacy & Security → Accessibility."
            return
        }
        let folder = url.deletingLastPathComponent()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(folder.path, forType: .string)
        // ⇧⌘G — "Go to Folder" sheet u Open dijalogu (isto kao Default Folder X).
        _ = sendKeystroke(keyCode: 5, flags: [.maskCommand, .maskShift]) // G
        Thread.sleep(forTimeInterval: 0.45)
        _ = sendKeystroke(keyCode: 9, flags: .maskCommand) // V — paste path
        Thread.sleep(forTimeInterval: 0.25)
        _ = sendKeystroke(keyCode: 36, flags: []) // Enter — idi tamo
        lastMessage = "Dialog moved to \(folder.lastPathComponent)"
    }

    func revealInDialog(url: URL) { driveOpenPanel(to: url) }

    // MARK: - Pristupacnost / aktivacija

    func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Stari zapis (drugi potpis) ostaje u listi i izgleda ukljucen, a ne
    /// vazi za ovaj build. Brise SAMO FinderFlow Accessibility zapis, pa
    /// sistem pita iznova za trenutni potpis.
    func resetAndPromptAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.finderflow.app"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        MailAttachDiag.log("tccutil reset status=\(p.terminationStatus) \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        promptAccessibility()
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func activateMail() {
        let id = "com.apple.mail" as CFString
        if let apps = LSCopyApplicationURLsForBundleIdentifier(id, nil)?.takeRetainedValue() as? [URL],
           let appURL = apps.first {
            NSWorkspace.shared.open(appURL)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
        }
    }

    private func sendKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard accessibilityTrusted() else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        // Mala pauza izmedju down/up da ciljana app registruje combo.
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - Stabilan potpis ("FinderFlow Dev")

/// Ad-hoc potpis menja cdhash svakim buildom, pa macOS zaboravi
/// Accessibility dozvolu. Self-signed cert u login keychainu daje stabilan
/// designated requirement (identifier + certificate leaf); build-local.sh ga
/// sam koristi kad postoji. Nepovereni cert je dovoljan — trust se ne dira.
enum FFSigningIdentity {
    static let name = "FinderFlow Dev"

    static func isInstalled() -> Bool {
        run("/usr/bin/security", ["find-identity", "-p", "codesigning"]).out.contains("\"\(name)\"")
    }

    static func appIsSignedWithIt() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        else { return false }
        return (SecCertificateCopySubjectSummary(leaf) as String?) == name
    }

    /// Vraca poruku greske ili nil. Bez admin lozinke.
    static func create() -> String? {
        if isInstalled() { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ff-sign-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return error.localizedDescription }
        defer { try? fm.removeItem(at: dir) }
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        let p12 = dir.appendingPathComponent("id.p12").path
        let pass = UUID().uuidString
        let keychain = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
        // NOTE: `security import -P` still takes the password on argv (no env/file
        // option). The openssl step below already avoids argv via env: so the
        // password is only briefly visible for the final import, and the temp
        // dir is 0700 with immediate cleanup.
        let steps: [(String, [String], [String: String]?)] = [
            ("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
                                  "-days", "3650", "-nodes", "-subj", "/CN=\(name)",
                                  "-addext", "keyUsage=critical,digitalSignature",
                                  "-addext", "extendedKeyUsage=critical,codeSigning",
                                  "-addext", "basicConstraints=critical,CA:false"], nil),
            ("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                                  "-passout", "env:FF_P12_PASS", "-name", name], ["FF_P12_PASS": pass]),
            ("/usr/bin/security", ["import", p12, "-k", keychain, "-P", pass, "-T", "/usr/bin/codesign"], nil),
        ]
        for (tool, args, extraEnv) in steps {
            let r = run(tool, args, extraEnv: extraEnv)
            guard r.status == 0 else {
                return "\((tool as NSString).lastPathComponent): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        MailAttachDiag.log("signing identity created")
        return isInstalled() ? nil : "Certifikat uvezen, ali ga codesign ne vidi."
    }

    private static func run(_ tool: String, _ args: [String], extraEnv: [String: String]? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let extraEnv {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            p.environment = env
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
