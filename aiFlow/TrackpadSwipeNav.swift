import AppKit

// MARK: - Trackpad swipe → Back / Forward (Finder/Safari convention)
//
// Two-finger swipe right = Back, swipe left = Forward.
//
// Implemented as an app-wide LOCAL scrollWheel monitor that only OBSERVES:
// every event is returned unmodified, so normal scrolling never breaks.
// Navigation fires only when a gesture looks like a deliberate swipe —
// short, mostly horizontal, ending with enough travel — by posting the same
// .ffGoBack / .ffGoForward notifications the menu shortcuts already use.
//
// Safety gates (avoid hijacking real scrolls):
// - trackpad only (hasPreciseScrollingDeltas; plain mice untouched),
// - fling tails ignored (momentumPhase),
// - OFF in Columns mode (horizontal two-finger scroll owns the gesture there),
// - OFF while a sheet is attached, while editing text, or when the key window
//   isn't the main browser window (SwiftUI Settings windows are NSPanels).
final class TrackpadSwipeNav {
    static let shared = TrackpadSwipeNav()

    /// Set by ContentView: false in Columns mode.
    var browserSwipeEnabled = true

    /// Travel (pt) that commits a swipe — a firm flick, below a full scroll.
    private let threshold: CGFloat = 80

    private var monitor: Any?
    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var startTime = Date.distantPast
    private var active = false

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observe(event)
            return event   // never swallow: scrolling always keeps working
        }
    }

    private func observe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        guard event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) {
            accumX = 0
            accumY = 0
            startTime = Date()
            active = true
        } else if event.phase.contains(.changed) {
            if !active {
                // Monitor attached mid-gesture: start tracking late, don't
                // evaluate this one (no began baseline).
                active = true
                accumX = 0
                accumY = 0
                startTime = Date()
                return
            }
            accumX += event.scrollingDeltaX
            accumY += event.scrollingDeltaY
        } else if event.phase.contains(.ended) {
            defer { active = false }
            guard active else { return }
            commitIfSwipe(inverted: event.isDirectionInvertedFromDevice)
        } else if event.phase.contains(.cancelled) {
            active = false
        }
    }

    private func commitIfSwipe(inverted: Bool) {
        let dx = accumX, dy = accumY
        guard abs(dx) > threshold,
              abs(dx) > 2 * abs(dy),
              Date().timeIntervalSince(startTime) < 1.0
        else { return }
        guard browserSwipeEnabled, canNavigateNow() else { return }
        // Physical finger direction, independent of the Natural-scroll setting:
        // with Natural ON deltas track the fingers (right = +), with it OFF
        // they run opposite — hence the XOR with the inversion flag.
        let fingersRight = (dx > 0) == inverted
        NotificationCenter.default.post(
            name: fingersRight ? .ffGoBack : .ffGoForward, object: nil)
    }

    private func canNavigateNow() -> Bool {
        guard !isEditingText() else { return false }
        guard let win = NSApp.keyWindow,
              win.attachedSheet == nil,
              !(win is NSPanel) else { return false }
        return true
    }
}

// MARK: - Backspace → Enclosing Folder (Windows-style "up")

// The hidden SwiftUI Button with `.keyboardShortcut(.delete)` in ContentView
// never fires reliably: when focus sits in the file Table/ScrollView the
// plain ⌫ keyDown never reaches the hidden button (and `.delete` maps to
// forward-delete on some macOS versions). So Backspace did nothing.
//
// This app-wide LOCAL keyDown monitor handles it at AppKit level, posting
// the same .ffGoUp notification the Go menu already uses:
// - keyCode 51 = ⌫ Backspace (the key labeled "delete" on Mac keyboards),
// - keyCode 117 = ⌦ forward delete (Fn+⌫) — same "leave the folder" action.
// Event is swallowed (nil) only when it actually navigates, so the hidden
// Button fallback can't double-fire (up two levels).
// Safety gates mirror TrackpadSwipeNav: no navigation while editing text
// (rename / search / path bar must keep ⌫ for text), while a sheet is up,
// or when the key window isn't the main browser window. ⌘⌫ (Trash) and
// ⌥/⌃ combos are never touched — only plain Backspace navigates.
final class BackspaceUpNav {
    static let shared = BackspaceUpNav()

    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            guard !isEditingText() else { return event }
            guard let win = NSApp.keyWindow,
                  win.attachedSheet == nil,
                  !(win is NSPanel) else { return event }
            NotificationCenter.default.post(name: .ffGoUp, object: nil)
            return nil
        }
    }
}
