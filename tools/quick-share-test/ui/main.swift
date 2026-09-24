import Foundation
import AppKit
import SwiftUI

guard ProcessInfo.processInfo.environment["FF_SHARE_TEST_MODE"] == "1", ProcessInfo.processInfo.environment["FF_SHARE_DIR"] != nil else { fatalError("Test isolation required") }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let root = SecureSharePaths.root
try SecureSharePaths.prepare()
let source = root.appendingPathComponent("Synthetic.txt")
try Data("FinderFlow automatic Cloudflare sharing — synthetic test only.\n".utf8).write(to:source)
Task { @MainActor in SecureShareWindowManager.shared.open(source) }
app.run()
