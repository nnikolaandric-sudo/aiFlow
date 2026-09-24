import Foundation
import Darwin

// A pipe-bound supervisor ensures cloudflared exits even if the app crashes.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--quick-tunnel" {
    // Hardening: argv comes from whoever execs this helper. Validate before use.
    // - stdin must be a pipe (parent launches with a control Pipe, not a TTY)
    // - binary must be the bundled Helpers/cloudflared-<arch> inside our .app
    // - port must be a numeric loopback port
    if isatty(STDIN_FILENO) != 0 { exit(1) }
    let binaryArg = CommandLine.arguments[2]
    let portArg = CommandLine.arguments[3]
    guard let portNum = Int(portArg), (1...65535).contains(portNum) else { exit(1) }
    let binaryURL = URL(fileURLWithPath: binaryArg).standardizedFileURL
    let agentURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let contentsURL = agentURL.deletingLastPathComponent().deletingLastPathComponent()
    let helpersDir = contentsURL.appendingPathComponent("Helpers").standardizedFileURL
    let allowed = Set([
        helpersDir.appendingPathComponent("cloudflared-arm64").standardizedFileURL.path,
        helpersDir.appendingPathComponent("cloudflared-x86_64").standardizedFileURL.path,
    ])
    guard allowed.contains(binaryURL.path),
          FileManager.default.isExecutableFile(atPath: binaryURL.path) else { exit(1) }
    let child = Process()
    child.executableURL = binaryURL
    let port = String(portNum)
    child.arguments = ["tunnel", "--config", "/dev/null", "--no-autoupdate", "--protocol", "http2", "--url", "http://127.0.0.1:\(port)", "--http-host-header", "127.0.0.1:\(port)", "--metrics", "127.0.0.1:0"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
    do { try child.run() } catch { exit(1) }
    let parent = getppid()
    // poll avoids handlers racing Process.run, and catches parent death/pipe closure.
    while child.isRunning {
        var descriptor = pollfd(fd:STDIN_FILENO,events:Int16(POLLIN|POLLHUP),revents:0)
        if poll(&descriptor,1,500) > 0 || getppid() != parent {
            child.terminate()
            for _ in 0..<20 { if !child.isRunning { break }; usleep(100_000) }
            if child.isRunning { kill(child.processIdentifier,SIGKILL) }
            child.waitUntilExit(); exit(0)
        }
    }
    exit(child.terminationStatus)
}
let relay = SecureShareRelayClient()
let quick = QuickShareRuntime()
Task {
    // Both watchers are idle unless their explicitly selected mode is enabled.
    await relay.start(); await quick.start()
}
RunLoop.main.run()
