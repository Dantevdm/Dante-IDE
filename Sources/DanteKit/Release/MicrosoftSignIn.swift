import CryptoKit
import Foundation
import Network
import Security

/// Signing in to Azure DevOps with a Microsoft work or school account, instead of a personal
/// access token: the authorisation code flow with PKCE, in the person's own browser (so their
/// MFA and company sign-in rules apply), redirected to a one-shot listener on this Mac. Only
/// the refresh token is kept, in the Keychain; access tokens live in memory for their hour.
///
/// Dante has no app registration of its own, so it signs in as the Azure CLI's public client,
/// which Microsoft allows to redirect to localhost. `DANTE_AZURE_CLIENT_ID` swaps in another.
public enum MicrosoftSignIn {
    public static let defaultClientID = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    /// Azure DevOps's resource id: tokens for it work on dev.azure.com.
    public static let azureDevOpsScope = "499b84ac-1321-427f-aa17-267ca6975798/.default offline_access"
    static let authority = URL(string: "https://login.microsoftonline.com/organizations/oauth2/v2.0")!

    public static var clientID: String {
        ProcessInfo.processInfo.environment["DANTE_AZURE_CLIENT_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultClientID
    }

    // MARK: Pure parts

    /// A PKCE pair: the verifier stays here, the challenge goes in the browser's URL.
    public struct PKCE: Equatable, Sendable {
        public var verifier: String
        public var challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = MicrosoftSignIn.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public static func random() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return PKCE(verifier: MicrosoftSignIn.base64URL(Data(bytes)))
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomState() -> String { PKCE.random().verifier }

    /// The page the browser opens.
    public static func authorizeURL(clientID: String = clientID, redirect: URL, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authority.appending(path: "authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: azureDevOpsScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    public enum Failure: Error, Equatable, Sendable {
        case cancelled, mismatchedState, refused(String), failed(String)

        public var message: String {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .mismatchedState: "The sign-in reply didn't match this request, so Dante ignored it."
            case .refused(let text): "Microsoft refused the sign-in: \(text)"
            case .failed(let text): text
            }
        }
    }

    /// The code from the redirect's request line (`GET /?code=…&state=… HTTP/1.1`).
    public static func code(fromRequest request: String, state: String) -> Result<String, Failure>? {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        if items["code"] == nil && items["error"] == nil { return nil }   // A favicon or the like.
        guard items["state"] == state else { return .failure(.mismatchedState) }
        if let error = items["error"] {
            if error == "access_denied" { return .failure(.cancelled) }
            return .failure(.refused(items["error_description"]?.components(separatedBy: "\r\n").first ?? error))
        }
        return items["code"].map { .success($0) }
    }

    /// What the token endpoint gives back.
    public struct Tokens: Equatable, Sendable {
        public var access: String
        public var refresh: String?
        public var expires: Date
        /// Who signed in, from the ID token's claims when there is one.
        public var account: String?

        public var isFresh: Bool { expires.timeIntervalSinceNow > 120 }
    }

    public static func tokens(_ data: Data, now: Date = .now) -> Result<Tokens, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.failed("Microsoft's answer wasn't readable.")) }
        if let error = json["error"] as? String {
            let text = (json["error_description"] as? String)?.components(separatedBy: "\r\n").first ?? error
            return .failure(.refused(text))
        }
        guard let access = json["access_token"] as? String else { return .failure(.failed("Microsoft's answer had no access token.")) }
        let seconds = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return .success(Tokens(access: access, refresh: json["refresh_token"] as? String, expires: now.addingTimeInterval(seconds),
                               account: (json["id_token"] as? String).flatMap(accountName)))
    }

    /// `preferred_username` (or `upn`) from a JWT's claims, without checking the signature:
    /// it's only a label.
    static func accountName(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["preferred_username"] as? String ?? claims["upn"] as? String
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }

    // MARK: Talking to Microsoft

    static func redeem(_ fields: [String: String]) async -> Result<Tokens, Failure> {
        var request = URLRequest(url: authority.appending(path: "token"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return tokens(data)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Signs in through the browser: `open` shows Microsoft's page (the app passes NSWorkspace).
    /// Waits up to five minutes for the redirect.
    public static func signIn(open: @Sendable (URL) -> Void) async -> Result<Tokens, Failure> {
        let pkce = PKCE.random(), state = randomState()
        let listener: Loopback
        do { listener = try await Loopback.start(state: state) } catch { return .failure(.failed("Dante couldn't listen for the sign-in reply: \(error.localizedDescription)")) }
        defer { listener.stop() }
        let redirect = URL(string: "http://localhost:\(listener.port)")!
        open(authorizeURL(redirect: redirect, pkce: pkce, state: state))
        let reply = await listener.waitForCode(timeout: .seconds(300))
        guard case .success(let code) = reply else {
            if case .failure(let failure) = reply { return .failure(failure) }
            return .failure(.cancelled)
        }
        let result = await redeem(["client_id": clientID, "grant_type": "authorization_code", "code": code,
                                   "redirect_uri": redirect.absoluteString, "code_verifier": pkce.verifier, "scope": azureDevOpsScope])
        if case .success(let tokens) = result { MicrosoftAccount.save(tokens) }
        return result
    }

    public static func refresh(_ refreshToken: String) async -> Result<Tokens, Failure> {
        await redeem(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken, "scope": azureDevOpsScope])
    }
}

// MARK: The redirect

/// A listener on a free port that takes one browser request carrying the code, answers with
/// a short page and stops. Connections from anywhere but this Mac are dropped.
final class Loopback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dante.signin")
    private(set) var port: UInt16 = 0
    private var continuation: CheckedContinuation<Result<String, MicrosoftSignIn.Failure>?, Never>?
    /// A reply that came before anyone waited for it.
    private var early: Result<String, MicrosoftSignIn.Failure>?
    private var answered = false
    private var ready = false
    private let state: String

    private init(listener: NWListener, state: String) {
        self.listener = listener
        self.state = state
    }

    static func start(state: String) async throws -> Loopback {
        let listener = try NWListener(using: .tcp, on: .any)
        let loopback = Loopback(listener: listener, state: state)
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            // The handler runs on the loopback's queue, so `ready` needs no lock.
            listener.stateUpdateHandler = { state in
                guard !loopback.ready else { return }
                switch state {
                case .ready:
                    loopback.ready = true
                    loopback.port = listener.port?.rawValue ?? 0
                    started.resume()
                case .failed(let error):
                    loopback.ready = true
                    started.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in loopback.accept(connection) }
            listener.start(queue: loopback.queue)
        }
        return loopback
    }

    func waitForCode(timeout: Duration) async -> Result<String, MicrosoftSignIn.Failure>? {
        await withTaskGroup(of: Result<String, MicrosoftSignIn.Failure>?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.queue.async {
                        if self.answered {
                            continuation.resume(returning: self.early)
                        } else {
                            self.continuation = continuation
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                self.finish(nil)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Hands over the first answer only; on the queue.
    private func answer(_ result: Result<String, MicrosoftSignIn.Failure>?) {
        guard !answered else { return }
        answered = true
        if let continuation {
            continuation.resume(returning: result)
            self.continuation = nil
        } else {
            early = result
        }
    }

    private func finish(_ result: Result<String, MicrosoftSignIn.Failure>?) {
        queue.async { self.answer(result) }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint, !Self.isLoopback(host) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let result = MicrosoftSignIn.code(fromRequest: request, state: self.state)
            let body: String = switch result {
            case .success?: "Signed in. You can close this tab and go back to Dante."
            case .failure(let failure)?: failure.message
            case nil: ""
            }
            let page = "<!doctype html><meta charset=utf-8><title>Dante</title><body style=\"font:15px -apple-system,sans-serif;margin:48px\"><p>\(body)</p>"
            let response = "HTTP/1.1 \(result == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let result { self.answer(result) }
        }
    }

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): address == .loopback
        case .ipv6(let address): address == .loopback || address.asIPv4 == .loopback
        case .name(let name, _): name == "localhost"
        @unknown default: false
        }
    }
}

// MARK: Keeping it

/// The signed-in Microsoft account on this Mac: its refresh token in the Keychain and a
/// fresh access token in memory.
public enum MicrosoftAccount {
    static let service = "dev.dante.ide.microsoft"
    static let accountKey = "dante.microsoftAccount"
    nonisolated(unsafe) private static var cached: MicrosoftSignIn.Tokens?
    private static let lock = NSLock()

    /// Who is signed in, for the label beside Sign out.
    public static var name: String? { UserDefaults.standard.string(forKey: accountKey) }
    public static var isSignedIn: Bool { refreshToken != nil }

    static var refreshToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "azure-devops",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    static func save(_ tokens: MicrosoftSignIn.Tokens) {
        lock.withLock { cached = tokens }
        if let account = tokens.account { UserDefaults.standard.set(account, forKey: accountKey) }
        guard let refresh = tokens.refresh else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "azure-devops"]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(refresh.utf8)
        item[kSecAttrLabel as String] = "Dante: Microsoft sign-in for Azure DevOps"
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func signOut() {
        lock.withLock { cached = nil }
        UserDefaults.standard.removeObject(forKey: accountKey)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    /// An access token for dev.azure.com, refreshed when it's nearly out. Nil when nobody is
    /// signed in or Microsoft no longer accepts the sign-in (then it's forgotten).
    public static func accessToken() async -> String? {
        if let fresh = lock.withLock({ cached }), fresh.isFresh { return fresh.access }
        guard let refresh = refreshToken else { return nil }
        switch await MicrosoftSignIn.refresh(refresh) {
        case .success(let tokens):
            var kept = tokens
            if kept.refresh == nil { kept.refresh = refresh }
            save(kept)
            return tokens.access
        case .failure(.refused):
            signOut()
            return nil
        case .failure:
            return nil
        }
    }
}
