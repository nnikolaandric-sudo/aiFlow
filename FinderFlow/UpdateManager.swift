import Foundation
import AppKit
import SwiftUI
import CryptoKit

/// Checks GitHub Releases for a newer aiFlow build and can download + install
/// the .dmg with one click (quit → replace → relaunch). aiFlow ships from the
/// nnikolaandric-sudo/FinderFlow fork; upstream FinderFlow releases are a
/// different app and must never be offered as an update.
@MainActor
final class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        // sha256 travels WITH the offer: the old shared pendingSHA256 could be
        // overwritten by a concurrent re-check between download start and the
        // integrity guard, failing a good download (fail-closed, but wrong).
        case available(version: String, notes: String, dmgURL: URL, sha256: String?)
        case downloading(progress: Double)
        case installing
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let repoOwner = "nnikolaandric-sudo"
    private let repoName  = "FinderFlow"
    private let checkInterval: TimeInterval = 12 * 3600   // twice a day max

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoCheck) }
    }

    func checkIfNeeded(force: Bool = false) {
        guard autoCheckEnabled || force else { return }
        if !force {
            let last = UserDefaults.standard.double(forKey: Keys.lastCheck)
            guard Date().timeIntervalSince1970 - last >= checkInterval else { return }
        }
        Task { await checkForUpdates(force: force) }
    }

    func checkForUpdates(force: Bool = false) async {
        phase = .checking

        do {
            let release = try await fetchLatestRelease()
            // Stampiraj SAMO uspesnu proveru: pad (offline) ne sme da ugusi
            // retry na 12h — sledeci launch ponovo proverava.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheck)
            let latest  = release.version
            guard isVersion(latest, newerThan: currentVersion) else {
                phase = .upToDate
                return
            }
            if !force, UserDefaults.standard.string(forKey: Keys.dismissedVersion) == latest {
                phase = .idle
                return
            }
            phase = .available(version: latest, notes: release.notes, dmgURL: release.dmgURL, sha256: release.sha256)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func dismissAvailableUpdate() {
        if case .available(let version, _, _, _) = phase {
            UserDefaults.standard.set(version, forKey: Keys.dismissedVersion)
        }
        phase = .idle
    }

    /// Download the release DMG and hand off to a short shell script that replaces
    /// the running .app and relaunches — the only reliable pattern on macOS.
    func downloadAndInstall() async {
        guard case .available(_, _, let dmgURL, let expectedSHA256) = phase else { return }
        let installDir = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installDir.path) else {
            phase = .error("Move aiFlow to Applications (or another writable folder), then try again.")
            return
        }
        phase = .downloading(progress: 0)

        do {
            let localDMG = try await downloadDMG(from: dmgURL) { [weak self] p in
                Task { @MainActor in self?.phase = .downloading(progress: p) }
            }
            // Fail closed: a download that can't be checked is never installed.
            guard let expected = expectedSHA256,
                  try Self.sha256(of: localDMG).caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: localDMG)
                phase = .error("Download failed integrity check. Try again later or download manually from GitHub.")
                return
            }
            phase = .installing
            try launchInstaller(dmgPath: localDMG.path, expectedSHA256: expected)
            // App quits — no return
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - GitHub API

    private struct ReleaseInfo {
        let version: String
        let notes:   String
        let dmgURL:  URL
        let sha256:  String?   // expected DMG hash from release asset
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let body:     String?
        let assets:   [GHAsset]
    }

    private struct GHAsset: Decodable {
        let name:                  String
        let browser_download_url:  String
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("aiFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("Could not reach GitHub (status \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let dmgAsset = release.assets.first(where: {
            $0.name.hasSuffix(".dmg") && !$0.name.hasSuffix(".dmg.sha256")
        }), let dmgURL = URL(string: dmgAsset.browser_download_url),
              // Defense in depth: release assets must come over TLS — a
              // downgraded/MITM'd http URL (with a matching forged .sha256
              // asset) must never reach the downloader.
              dmgURL.scheme?.lowercased() == "https" else {
            throw UpdateError.noAsset
        }
        let sha256 = try await fetchExpectedSHA256(for: dmgAsset.name, assets: release.assets)
        return ReleaseInfo(version: version, notes: release.body ?? "", dmgURL: dmgURL, sha256: sha256)
    }

    /// Reads the companion `aiFlow-x.y.dmg.sha256` asset published with each release.
    private func fetchExpectedSHA256(for dmgName: String, assets: [GHAsset]) async throws -> String {
        guard let hashAsset = assets.first(where: { $0.name == "\(dmgName).sha256" }),
              let hashURL = URL(string: hashAsset.browser_download_url),
              hashURL.scheme?.lowercased() == "https" else {
            throw UpdateError.noChecksum
        }
        var hashReq = URLRequest(url: hashURL, timeoutInterval: 20)
        hashReq.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: hashReq)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("Could not fetch release checksum")
        }
        // Redirect check: samo inicijalni scheme je https-proveren — https→http
        // downgrade bi prosao do hash-checka. Odbaci ne-TLS finalni URL.
        if let finalURL = resp.url, finalURL.scheme?.lowercased() != "https" {
            throw UpdateError.network("Insecure redirect during update check")
        }
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first ?? ""
        guard line.count == 64, line.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.badChecksum
        }
        return line
    }

    private static func sha256(of file: URL) throws -> String {
        // Stream in 1MB chunks — the old `Data(contentsOf:)` loaded the whole
        // .dmg (hundreds of MB) into RAM at once.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download

    private func downloadDMG(from url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("Download failed")
        }
        // https→http downgrade pri redirektu: hash bi pao samo ako MITM ne
        // forguje i .sha256 — odbaci ne-TLS finalni URL odmah.
        if let finalURL = response.url, finalURL.scheme?.lowercased() != "https" {
            throw UpdateError.network("Insecure redirect during download")
        }
        onProgress(1.0)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFlow-update-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - Install (detach, replace, relaunch)

    private func launchInstaller(dmgPath: String, expectedSHA256: String) throws {
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderflow-install-\(UUID().uuidString).sh").path

        // Everything variable reaches the script as an argument ($1…$5), never
        // spliced into its text, so an install folder whose name contains $(…),
        // backticks or quotes can't inject shell commands.
        let script = #"""
        #!/bin/bash
        set -euo pipefail
        DMG="$1"; APP_PATH="$2"; APP_PID="$3"; BUNDLE_ID="$4"; EXPECTED_HASH="$5"
        APP_DIR="$(dirname "$APP_PATH")"; APP_NAME="$(basename "$APP_PATH")"
        STAGED="$APP_DIR/.$APP_NAME.update"; BACKUP="$APP_DIR/.$APP_NAME.previous"
        MOUNT=""
        cleanup() {
          if [ -n "$MOUNT" ]; then /usr/bin/hdiutil detach "$MOUNT" -quiet || /usr/bin/hdiutil detach "$MOUNT" -force -quiet || true; fi
          rm -rf "$STAGED"
          rm -f "$DMG" "$0"
        }
        trap cleanup EXIT

        # Wait up to two minutes for this copy of aiFlow to quit.
        # (Bash comments only in here: a "//" line runs as a command, fails
        # with "is a directory" and set -e aborts every update after quit.)
        for _ in $(seq 240); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
        if kill -0 "$APP_PID" 2>/dev/null; then echo "aiFlow didn't quit; update skipped." >&2; exit 1; fi

        # Apsolutne putanje: goli shasum/hdiutil/ditto/open/find/awk preko PATH
        # bi hijackovan PATH pretvorio u code exec. PlistBuddy je vec apsolutan.
        SHASUM=/usr/bin/shasum; HDIUTIL=/usr/bin/hdiutil; DITTO=/usr/bin/ditto
        OPEN=/usr/bin/open; FIND=/usr/bin/find; AWK=/usr/bin/awk
        # Re-verify at the point of use: the DMG sat in /tmp while the app
        # quit, so a swap after the Swift-side check must not install.
        # Both sides quoted → literal compare, no glob matching.
        ACTUAL_HASH="$("$SHASUM" -a 256 "$DMG" | "$AWK" '{ print $1 }')"
        [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || { echo "Update image failed integrity check." >&2; exit 1; }

        # No -quiet here: it closes stdout, which is where the mount point is printed.
        MOUNT="$("$HDIUTIL" attach "$DMG" -nobrowse -noautoopen -readonly | "$AWK" -F'\t' '/\/Volumes\// { print $NF }' | tail -n 1)"
        NEW_APP="$("$FIND" "$MOUNT" -maxdepth 1 -type d -name '*.app' | head -n 1)"
        [ -n "$NEW_APP" ] || { echo "No app found in the update image." >&2; exit 1; }
        NEW_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist")"
        [ "$NEW_ID" = "$BUNDLE_ID" ] || { echo "Update image holds $NEW_ID, expected $BUNDLE_ID." >&2; exit 1; }

        # Copy beside the old app, then swap: a failed copy never leaves a
        # half-installed app, and files removed in the new version don't linger.
        rm -rf "$STAGED" "$BACKUP"
        "$DITTO" "$NEW_APP" "$STAGED"
        xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true
        mv "$APP_PATH" "$BACKUP"
        if ! mv "$STAGED" "$APP_PATH"; then mv "$BACKUP" "$APP_PATH"; exit 1; fi
        rm -rf "$BACKUP"
        "$OPEN" "$APP_PATH"
        """#

        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [
            scriptPath,
            dmgPath,
            Bundle.main.bundleURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleIdentifier ?? "com.finderflow.app",
            expectedSHA256.lowercased(),
        ]
        try proc.run()

        NSApp.terminate(nil)
    }

    // MARK: - Semver compare

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n  = max(pa.count, pb.count)
        for i in 0..<n {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    private enum Keys {
        static let lastCheck        = "ffUpdateLastCheck"
        static let dismissedVersion = "ffUpdateDismissedVersion"
        static let autoCheck        = "ffAutoCheckUpdates"
    }

    private enum UpdateError: LocalizedError {
        case network(String)
        case noAsset
        case noChecksum
        case badChecksum

        var errorDescription: String? {
            switch self {
            case .network(let m): return m
            case .noAsset:        return "No .dmg found on the latest GitHub release."
            case .noChecksum:     return "Release is missing a checksum file — update blocked for safety."
            case .badChecksum:    return "Release checksum file is invalid."
            }
        }
    }
}

// MARK: - In-app update banner

struct UpdateBanner: View {
    @ObservedObject var manager: UpdateManager
    let version: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(FFTheme.heroGradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            (Text("aiFlow ") + Text(version).bold() + Text(" is available — you have \(manager.currentVersion)."))
                .truncationMode(.middle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            if case .downloading(let p) = manager.phase {
                // Progres stiže samo na kraju (URLSession.download nema
                // inkrementalni callback) — do tada neodređeni spinner.
                if p <= 0 || p >= 1 {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ProgressView(value: p)
                        .frame(width: 80)
                }
                Text("Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .installing = manager.phase {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Update Now") {
                    Task { await manager.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Later") { manager.dismissAvailableUpdate() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(FFTheme.softGradient)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}
