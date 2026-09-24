import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Google OAuth 2.0 (Desktop / loopback + PKCE, bez client secreta)
//
// Flow (preporučen za desktop app-ove, https://developers.google.com/identity/protocols/oauth2/native-app):
//  1. Napravimo PKCE code_verifier + code_challenge (S256).
//  2. Podignemo loopback HTTP server na 127.0.0.1:<random port> (/callback).
//  3. Otvorimo sistemski browser na accounts.google.com/o/oauth2/v2/auth
//     sa redirect_uri=http://127.0.0.1:<port>/callback .
//     Google Desktop client tip dozvoljava BILO KOJI loopback port bez registracije.
//  4. Korisnik se uloguje, Google redirectuje na loopback, mi uhvatimo ?code=.
//  5. Razmenimo code + code_verifier za refresh_token + access_token.
//  6. refresh_token ide u Keychain, access_token se osvežava po potrebi.
//
// Potreban je JEDAN Google Cloud "OAuth client ID" tipa "Desktop app":
//   Google Cloud Console → APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app
// Potrebno je uključiti "Google Drive API" + "OpenID Connect" (za email/ime).
// Client ID se unosi jednom u Settings → Google Drive i važi za sve naloge.

enum GoogleOAuthError: LocalizedError {
    case noClientID
    case cancelled
    case network(Error)
    case badResponse(String)
    case tokenRejected(String)
    case loopbackFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .noClientID:
            return "Enter your Google Client ID in Settings → Google Drive (Desktop app type, from Google Cloud Console)."
        case .cancelled:
            return "Sign-in was cancelled."
        case .network(let e):
            return "Network error: \(e.localizedDescription)"
        case .badResponse(let m):
            return m.isEmpty ? "Unexpected response from Google." : m
        case .tokenRejected(let m):
            return m.isEmpty ? "Google rejected the sign-in." : m
        case .loopbackFailed:
            return "Couldn't listen for the local callback URL (127.0.0.1). Check your firewall."
        case .timeout:
            return "Sign-in timed out (5 min) — please try again."
        }
    }
}

struct GoogleOAuthTokens {
    var accessToken: String
    var accessExpiry: Date
    var refreshToken: String? // stiže samo uz access_type=offline + prompt=consent (prvi put)
    var email: String
    var displayName: String
}

// MARK: - PKCE helperi

enum GooglePKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Minimalni loopback HTTP server (samo za ?code= hvatanje)

/// Osluskuje JEDAN OAuth povratak na 127.0.0.1. Nije web server opšte namene:
/// prihvata prvu GET konekciju, vadi `code`/`error` iz request line-a, vraća
/// success HTML i gasi se. Timeout 5 min.
/// Sve promenljivo stanje je iza `lock`, a `listener` se postavlja u `start()`
/// pre nego što bilo koji drugi thread vidi objekat — otud `@unchecked Sendable`.
final class GoogleLoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private let lock = NSLock()

    var port: UInt16 {
        UInt16(listener?.port?.rawValue ?? 0)
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            guard !finished else { lock.unlock(); cont.resume(throwing: GoogleOAuthError.cancelled); return }
            continuation = cont
            lock.unlock()
            // Timeout: 5 min
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(with: .failure(GoogleOAuthError.timeout))
            }
        }
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port.any)
        listener.service = nil
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: DispatchQueue(label: "FinderFlow.googleOAuth"))
        // Sačekaj da sistem dodeli port (do 2s)
        let deadline = Date().addingTimeInterval(2)
        while (listener.port?.rawValue ?? 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard (listener.port?.rawValue ?? 0) != 0 else { throw GoogleOAuthError.loopbackFailed }
    }

    func cancel() {
        finish(with: .failure(GoogleOAuthError.cancelled))
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive(on: conn) }
        }
        conn.start(queue: DispatchQueue(label: "FinderFlow.googleOAuthConn"))
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // "GET /callback?code=4/xxx&scope=... HTTP/1.1"
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let target = parts.count >= 2 ? parts[1] : ""
            var code: String?
            var oauthError: String?
            if let q = target.components(separatedBy: "?").last,
               target.contains("?") {
                for pair in q.components(separatedBy: "&") {
                    let kv = pair.components(separatedBy: "=")
                    guard kv.count == 2 else { continue }
                    let key = kv[0]
                    let val = kv[1].removingPercentEncoding ?? kv[1]
                    if key == "code" { code = val }
                    if key == "error" { oauthError = val }
                }
            }
            let ok = code != nil
            let title = ok ? "aiFlow connected ✓" : "Sign-in failed"
            let msg = ok
                ? "You can close this tab and return to aiFlow. Your Drive will sync."
                : "Error: \(oauthError ?? "unknown"). Close the tab and try again from aiFlow."
            let html = """
            <html><head><meta charset="utf-8"><title>\(title)</title></head>
            <body style="font-family:-apple-system,Helvetica,Arial,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f6f7f9;">
            <div style="background:white;padding:32px 40px;border-radius:16px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:420px;">
            <div style="font-size:44px;">\(ok ? "✅" : "⚠️")</div>
            <h2>\(title)</h2><p style="color:#555;">\(msg)</p>
            </div></body></html>
            """
            let body = Data(html.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(response.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in
                conn.cancel()
            })
            if let code {
                self.finish(with: .success(code))
            } else {
                self.finish(with: .failure(GoogleOAuthError.badResponse("Google rejected the sign-in (\(oauthError ?? "?")).")))
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        switch result {
        case .success(let code): cont?.resume(returning: code)
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    deinit { listener?.cancel() }
}

// MARK: - OAuth servis

enum GoogleOAuthService {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let userinfoEndpoint = "https://openidconnect.googleapis.com/v1/userinfo"
    static let scopes = [
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ].joined(separator: " ")

    /// Kompletan "Poveži nalog" flow: browser + loopback + razmena + userinfo.
    /// Vraća tokene + email/ime. Refresh token se čuva tek kad pozivalac snimi nalog.
    static func connectAccount(clientID: String) async throws -> GoogleOAuthTokens {
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { throw GoogleOAuthError.noClientID }

        let verifier = GooglePKCE.verifier()
        let challenge = GooglePKCE.challenge(for: verifier)
        let server = GoogleLoopbackServer()
        try server.start()
        let redirect = "http://127.0.0.1:\(server.port)/callback"

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"), // uvek vrati refresh_token (multi-account!)
            URLQueryItem(name: "include_granted_scopes", value: "false"),
        ]
        guard let authURL = comps.url else { throw GoogleOAuthError.badResponse("Couldn't build the auth URL.") }
        NSWorkspace.shared.open(authURL)

        async let codeTask: String = server.waitForCode()
        let code = try await codeTask

        return try await exchangeCode(code: code, verifier: verifier, redirect: redirect, clientID: client)
    }

    private static func exchangeCode(code: String, verifier: String, redirect: String, clientID: String) async throws -> GoogleOAuthTokens {
        let body: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ]
        let json = try await postForm(url: tokenEndpoint, fields: body)
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw GoogleOAuthError.tokenRejected(json["error_description"] as? String ?? json["error"] as? String ?? "")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let refresh = json["refresh_token"] as? String
        let (email, name) = try await fetchUserinfo(accessToken: access)
        return GoogleOAuthTokens(
            accessToken: access,
            accessExpiry: Date().addingTimeInterval(expiresIn - 60),
            refreshToken: refresh,
            email: email,
            displayName: name
        )
    }

    /// Osveži access token iz Keychain refresh tokena. Vraća (token, expiry).
    static func refreshAccessToken(clientID: String, refreshToken: String) async throws -> (String, Date) {
        let body: [String: String] = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let json = try await postForm(url: tokenEndpoint, fields: body)
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            let desc = json["error_description"] as? String ?? json["error"] as? String ?? ""
            // invalid_grant = opozvan/obrisan pristup → nalog mora ponovo na Connect
            throw GoogleOAuthError.tokenRejected(desc)
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (access, Date().addingTimeInterval(expiresIn - 60))
    }

    private static func fetchUserinfo(accessToken: String) async throws -> (String, String) {
        var req = URLRequest(url: URL(string: userinfoEndpoint)!, timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let email = json["email"] as? String ?? ""
            let name = json["name"] as? String ?? ""
            return (email, name)
        } catch {
            throw GoogleOAuthError.network(error)
        }
    }

    private static func postForm(url: String, fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if !(200...299).contains(status) {
                throw GoogleOAuthError.tokenRejected(json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)")
            }
            return json
        } catch let e as GoogleOAuthError {
            throw e
        } catch {
            throw GoogleOAuthError.network(error)
        }
    }
}
