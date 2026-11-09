import Foundation
import Security

/// Signing in to DigitalOcean the way its own command-line tools do: the authorisation code
/// flow with PKCE in the person's browser (already signed in there, with their 2FA), redirected
/// to a one-shot listener on this Mac. Dante registers itself as a public client once per Mac
/// (Dynamic Client Registration: no secret exists to leak), keeps the refresh token in the
/// Keychain, and holds access tokens in memory for their hour. Each refresh token works once,
/// so every refresh saves the new one. DigitalOcean redirects to the registered address exactly,
/// port included (loopback ports aren't matched loosely), so Dante listens on the port it
/// registered and updates the registration (RFC 7592) only when that port is taken.
public enum DOSignIn {
    static let cloud = URL(string: "https://cloud.digitalocean.com")!
    static let authorizeURL = cloud.appending(path: "v1/oauth/authorize")
    static let tokenURL = cloud.appending(path: "v1/oauth/token")
    static let registerURL = cloud.appending(path: "v1/oauth/register")
    static let revokeURL = cloud.appending(path: "v1/oauth/revoke")
    static let redirectPath = "/callback"

    public static func redirect(port: UInt16) -> String { "http://127.0.0.1:\(port)\(redirectPath)" }

    /// What Dante asks for: App Platform, the container registry it pushes images to, the
    /// metrics it shows, a console in a running component, and databases: reading them for their trusted sources, and creating
    /// the dev database a spec's `databases:` asks App Platform for. Nothing else.
    public static let scopes = [
        "account:read", "app:read", "app:create", "app:update", "app:delete", "app:access_console",
        "registry:read", "registry:create", "registry:update", "monitoring:read", "database:read", "database:create",
    ]

    /// The scope an error says the sign-in lacks: DigitalOcean answers "missing database create
    /// permission: rpc error: …" when a token without `database:create` asks for a dev database.
    public static func missingScope(in message: String) -> String? {
        let pattern = /missing ([a-z_]+) ([a-z_]+) permission/
        guard let match = message.lowercased().firstMatch(of: pattern) else { return nil }
        return "\(match.1):\(match.2)"
    }

    /// An error about a missing scope, in words, with what to do about it.
    public static func explain(_ message: String) -> String {
        guard let scope = missingScope(in: message) else { return message }
        let parts = scope.split(separator: ":")
        let what = parts.count == 2 ? "\(parts[1]) \(parts[0])s" : scope
        if scopes.contains(scope) {
            return "This DigitalOcean sign-in isn’t allowed to \(what) (\(scope)): it was granted before Dante asked for that. Sign out and sign in again to allow it."
        }
        return "This DigitalOcean sign-in isn’t allowed to \(what) (\(scope)), and Dante doesn’t ask for that. DigitalOcean said: \(message)"
    }

    public typealias Failure = MicrosoftSignIn.Failure

    // MARK: Pure parts

    /// The body of the registration, and of an update to it (which names the client).
    public static func registration(redirect: String, clientID: String? = nil) -> Data {
        var body: [String: Any] = [
            "client_name": "Dante",
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]
        if let clientID { body["client_id"] = clientID }
        return (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data()
    }

    public struct Client: Equatable, Sendable {
        public var id: String
        /// Lets Dante update or delete its registration; shown once, kept in the Keychain.
        public var registrationToken: String?
        /// The one address DigitalOcean sends the browser back to.
        public var redirect: String?

        public var port: UInt16? { redirect.flatMap { URL(string: $0)?.port }.flatMap { UInt16(exactly: $0) } }
    }

    public static func client(_ data: Data) -> Client? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["client_id"] as? String, !id.isEmpty else { return nil }
        return Client(id: id, registrationToken: json["registration_access_token"] as? String, redirect: (json["redirect_uris"] as? [String])?.first)
    }

    public static func authorize(clientID: String, redirect: URL, pkce: MicrosoftSignIn.PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Who signed in, from the token answer's `info`.
    public struct Person: Equatable, Sendable, Codable {
        public var name: String?
        public var email: String?
        public var team: String?

        public init(name: String?, email: String?, team: String?) {
            self.name = name
            self.email = email
            self.team = team
        }

        /// "Sam · Acme" (the team is what matters: it's whose bill a deploy goes on).
        public var label: String {
            [name ?? email, team].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        }
    }

    public struct Tokens: Equatable, Sendable {
        public var access: String
        public var refresh: String?
        public var expires: Date
        public var person: Person?
        /// The scopes granted, which may be fewer than asked for.
        public var scope: String?

        public var isFresh: Bool { expires.timeIntervalSinceNow > 120 }
    }

    public static func tokens(_ data: Data, now: Date = .now) -> Result<Tokens, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.failed("DigitalOcean's answer wasn't readable.")) }
        if let error = json["error"] as? String {
            return .failure(.refused((json["error_description"] as? String) ?? error))
        }
        guard let access = json["access_token"] as? String, !access.isEmpty else { return .failure(.failed("DigitalOcean's answer had no access token.")) }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        var person: Person?
        if let info = json["info"] as? [String: Any] {
            person = Person(name: info["name"] as? String, email: info["email"] as? String, team: info["team_name"] as? String)
        }
        return .success(Tokens(access: access, refresh: json["refresh_token"] as? String, expires: now.addingTimeInterval(seconds),
                               person: person, scope: json["scope"] as? String))
    }

    // MARK: Talking to DigitalOcean

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static func register(redirect: String) async -> Result<Client, Failure> {
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = registration(redirect: redirect)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201, let client = client(data) else {
                return .failure(.failed("DigitalOcean didn't register Dante for sign-in (\((response as? HTTPURLResponse)?.statusCode ?? 0))."))
            }
            return .success(client)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Points the registration at a new address; nil when DigitalOcean refuses (then Dante
    /// registers afresh). An update hands back no new registration token.
    static func update(_ client: Client, redirect: String) async -> Client? {
        guard let token = client.registrationToken else { return nil }
        var request = URLRequest(url: registerURL.appending(path: client.id))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = registration(redirect: redirect, clientID: client.id)
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let updated = Self.client(data), updated.redirect == redirect else { return nil }
        return Client(id: client.id, registrationToken: updated.registrationToken ?? token, redirect: redirect)
    }

    /// Dante's registration for this address: the saved one, updated, or a new one.
    static func client(for redirect: String, known: Client?) async -> Result<Client, Failure> {
        if let known {
            if known.redirect == redirect { return .success(known) }
            if let updated = await update(known, redirect: redirect) {
                DOAccount.save(client: updated)
                return .success(updated)
            }
        }
        let made = await register(redirect: redirect)
        if case .success(let client) = made { DOAccount.save(client: client) }
        return made
    }

    static func redeem(_ fields: [String: String]) async -> Result<Tokens, Failure> {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MicrosoftSignIn.form(fields)
        do {
            let (data, _) = try await session.data(for: request)
            return tokens(data)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Signs in through the browser (`open` is NSWorkspace in the app), waiting up to five
    /// minutes for the redirect.
    public static func signIn(open: @Sendable (URL) -> Void) async -> Result<Tokens, Failure> {
        let pkce = MicrosoftSignIn.PKCE.random(), state = MicrosoftSignIn.randomState()
        // Read once: each Keychain read can ask the person when the app's signature changed.
        let known = DOAccount.client
        let listener: Loopback
        do {
            if let port = known?.port, let known = try? await Loopback.start(state: state, provider: "DigitalOcean", port: port) {
                listener = known
            } else {
                listener = try await Loopback.start(state: state, provider: "DigitalOcean")
            }
        } catch {
            return .failure(.failed("Dante couldn't listen for the sign-in reply: \(error.localizedDescription)"))
        }
        defer { listener.stop() }
        let redirect = URL(string: Self.redirect(port: listener.port))!
        let registered: Client
        switch await client(for: redirect.absoluteString, known: known) {
        case .success(let found): registered = found
        case .failure(let failure): return .failure(failure)
        }
        open(authorize(clientID: registered.id, redirect: redirect, pkce: pkce, state: state))
        let reply = await listener.waitForCode(timeout: .seconds(300))
        guard case .success(let code) = reply else {
            if case .failure(let failure) = reply { return .failure(failure) }
            return .failure(.timedOut)
        }
        let result = await redeem(["grant_type": "authorization_code", "code": code, "client_id": registered.id,
                                   "code_verifier": pkce.verifier, "redirect_uri": redirect.absoluteString])
        if case .success(let tokens) = result { DOAccount.save(tokens) }
        return result
    }

    static func refresh(_ refreshToken: String, clientID: String) async -> Result<Tokens, Failure> {
        await redeem(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }

    static func revoke(_ access: String) async {
        var request = URLRequest(url: revokeURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MicrosoftSignIn.form(["token": access])
        _ = try? await session.data(for: request)
    }
}

/// The DigitalOcean sign-in on this Mac: the refresh token and Dante's client registration in
/// the Keychain, who signed in in user defaults (only a label), and the access token in memory.
public enum DOAccount {
    /// Per app, so a test copy never prompts for the real one's sign-in.
    static let service = (Bundle.main.bundleIdentifier ?? "dev.dante.ide") + ".digitalocean"
    static let personKey = "dante.digitalocean.person"
    static let clientKey = "dante.digitalocean.client"
    static let redirectKey = "dante.digitalocean.redirect"
    nonisolated(unsafe) private static var cached: DOSignIn.Tokens?
    /// Refresh tokens work once, so two refreshes at the same moment would sign the person out.
    private static let refreshing = RefreshGate()
    private static let lock = NSLock()

    public static var person: DOSignIn.Person? {
        UserDefaults.standard.data(forKey: personKey).flatMap { try? JSONDecoder().decode(DOSignIn.Person.self, from: $0) }
    }

    public static var isSignedIn: Bool { keychain("refresh") != nil }

    static var client: DOSignIn.Client? {
        guard let id = UserDefaults.standard.string(forKey: clientKey), !id.isEmpty else { return nil }
        return DOSignIn.Client(id: id, registrationToken: keychain("registration"), redirect: UserDefaults.standard.string(forKey: redirectKey))
    }

    static func save(client: DOSignIn.Client) {
        UserDefaults.standard.set(client.id, forKey: clientKey)
        UserDefaults.standard.set(client.redirect, forKey: redirectKey)
        if let token = client.registrationToken { store(token, as: "registration", label: "Dante: DigitalOcean client registration") }
    }

    static func save(_ tokens: DOSignIn.Tokens) {
        lock.withLock { cached = tokens }
        if let person = tokens.person, let data = try? JSONEncoder().encode(person) { UserDefaults.standard.set(data, forKey: personKey) }
        if let refresh = tokens.refresh { store(refresh, as: "refresh", label: "Dante: DigitalOcean sign-in") }
    }

    /// Revokes the access token and forgets the sign-in. Dante's client registration stays,
    /// so signing in again doesn't register another.
    public static func signOut() async {
        let access = lock.withLock { cached?.access }
        if let access { await DOSignIn.revoke(access) }
        forget()
    }

    static func forget() {
        lock.withLock { cached = nil }
        UserDefaults.standard.removeObject(forKey: personKey)
        delete("refresh")
    }

    /// A fresh access token, refreshed when it's nearly out. Nil when nobody is signed in or
    /// DigitalOcean no longer accepts the sign-in (then it's forgotten).
    public static func accessToken() async -> String? {
        if let fresh = lock.withLock({ cached }), fresh.isFresh { return fresh.access }
        return await refreshing.run {
            if let fresh = lock.withLock({ cached }), fresh.isFresh { return fresh.access }
            guard let refresh = keychain("refresh"), let client else { return nil }
            switch await DOSignIn.refresh(refresh, clientID: client.id) {
            case .success(let tokens):
                save(tokens)
                return tokens.access
            case .failure(.refused):
                forget()
                return nil
            case .failure:
                return nil
            }
        }
    }

    // MARK: Keychain

    private static func keychain(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func store(_ value: String, as account: String, label: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: label,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// Runs one refresh at a time; callers that arrive meanwhile wait for it and then see its token.
actor RefreshGate {
    private var running: Task<String?, Never>?

    func run(_ work: @escaping @Sendable () async -> String?) async -> String? {
        if let running { return await running.value }
        let task = Task { await work() }
        running = task
        let value = await task.value
        running = nil
        return value
    }
}
