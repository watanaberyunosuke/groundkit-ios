import CryptoKit
import Foundation

/// The parts of Supabase Auth and its REST API that GroundKit accounts use, over URLSession
/// (no SDK). The URL and publishable key come from Info.plist (`GKSupabaseURL`,
/// `GKSupabaseKey`); without them accounts are hidden and settings stay on the device.
nonisolated struct SupabaseConfig: Sendable, Hashable {
    var url: URL
    var key: String

    /// Where provider sign-in returns to the app (ASWebAuthenticationSession catches it).
    static let callbackScheme = "groundkit"
    static let callbackURL = "groundkit://auth-callback"
    /// Email links (confirm address, reset password) open the web dashboard, which handles
    /// them; the app then signs in with the password.
    static let webURL = "https://groundkit-dashboard.harrydatahub.com/"

    static func fromBundle(_ bundle: Bundle = .main) -> SupabaseConfig? {
        guard let raw = bundle.object(forInfoDictionaryKey: "GKSupabaseURL") as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true,
              let key = (bundle.object(forInfoDictionaryKey: "GKSupabaseKey") as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty
        else { return nil }
        return SupabaseConfig(url: url, key: key)
    }
}

nonisolated struct AuthSession: Codable, Sendable, Hashable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AuthUser

    /// Refresh a minute early so a request does not race the expiry.
    func needsRefresh(at now: Date = .now) -> Bool { expiresAt.timeIntervalSince(now) < 60 }
}

nonisolated struct AuthUser: Codable, Sendable, Hashable {
    var id: String
    var email: String?
    var providers: [String]
}

nonisolated struct SupabaseError: LocalizedError, Sendable, Equatable {
    var status: Int
    var code: String?
    var message: String

    var errorDescription: String? { message }
    /// The session is no longer valid (deleted user, revoked refresh token).
    var isSignedOut: Bool { status == 401 || code == "refresh_token_not_found" || code == "user_not_found" || code == "session_not_found" }
}

/// PKCE for provider sign-in: a random verifier and its S256 challenge.
nonisolated struct PKCE: Sendable {
    var verifier: String
    var challenge: String

    init(verifier: String = PKCE.random()) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    static func random(bytes: Int = 32) -> String {
        var g = SystemRandomNumberGenerator()
        return Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &g) }).base64URL
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated struct SupabaseClient: Sendable {
    var config: SupabaseConfig
    var session: URLSession = .shared

    // MARK: Auth

    func signUp(email: String, password: String, displayName: String?) async throws -> AuthSession? {
        var body: [String: Any] = ["email": email, "password": password]
        if let displayName, !displayName.isEmpty { body["data"] = ["display_name": displayName] }
        let data = try await send("auth/v1/signup", query: ["redirect_to": SupabaseConfig.webURL], json: body)
        // With email confirmation on (the default) there is no session until the link is opened.
        return try? Self.decodeSession(data)
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        try Self.decodeSession(await send("auth/v1/token", query: ["grant_type": "password"], json: ["email": email, "password": password]))
    }

    /// The page that starts a provider's sign-in; it ends at `callbackURL?code=...`.
    func authorizeURL(provider: String, pkce: PKCE, scopes: String? = nil) -> URL {
        var c = URLComponents(url: config.url.appending(path: "auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: SupabaseConfig.callbackURL),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ] + (scopes.map { [URLQueryItem(name: "scopes", value: $0)] } ?? [])
        return c.url!
    }

    /// The code from the provider callback, or the provider's error.
    static func code(fromCallback url: URL) throws -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = (c?.queryItems ?? []) + (URLComponents(string: "?" + (c?.fragment ?? ""))?.queryItems ?? [])
        if let code = items.first(where: { $0.name == "code" })?.value { return code }
        let message = items.first { $0.name == "error_description" }?.value ?? "Sign-in did not finish."
        throw SupabaseError(status: 400, code: items.first { $0.name == "error" }?.value, message: message)
    }

    func exchange(code: String, pkce: PKCE) async throws -> AuthSession {
        try Self.decodeSession(await send("auth/v1/token", query: ["grant_type": "pkce"],
                                          json: ["auth_code": code, "code_verifier": pkce.verifier]))
    }

    func refresh(_ refreshToken: String) async throws -> AuthSession {
        try Self.decodeSession(await send("auth/v1/token", query: ["grant_type": "refresh_token"], json: ["refresh_token": refreshToken]))
    }

    func resetPassword(email: String) async throws {
        _ = try await send("auth/v1/recover", query: ["redirect_to": SupabaseConfig.webURL], json: ["email": email])
    }

    func signOut(_ s: AuthSession) async throws {
        _ = try await send("auth/v1/logout", method: "POST", token: s.accessToken)
    }

    // MARK: Data

    func mergeSettings(_ request: MergeRequest, token: String) async throws -> MergeResponse {
        let body = try JSONEncoder().encode(request)
        let data = try await send("rest/v1/rpc/merge_settings", method: "POST", token: token, body: body,
                                  headers: ["Accept": "application/vnd.pgrst.object+json"])
        return try JSONDecoder().decode(MergeResponse.self, from: data)
    }

    func displayName(userID: String, token: String) async throws -> String? {
        let data = try await send("rest/v1/profiles", query: ["select": "display_name", "id": "eq.\(userID)"], method: "GET", token: token)
        return try JSONDecoder().decode([ProfileRow].self, from: data).first?.display_name ?? nil
    }

    func setDisplayName(_ name: String?, userID: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["display_name": name.map { $0 as Any } ?? NSNull()])
        _ = try await send("rest/v1/profiles", query: ["id": "eq.\(userID)"], method: "PATCH", token: token, body: body,
                           headers: ["Prefer": "return=minimal"])
    }

    func deleteAccount(token: String) async throws {
        _ = try await send("rest/v1/rpc/delete_own_account", method: "POST", token: token, body: Data("{}".utf8))
    }

    // MARK: Plumbing

    static func decodeSession(_ data: Data, now: Date = .now) throws -> AuthSession {
        let raw = try JSONDecoder().decode(RawSession.self, from: data)
        let expires = raw.expires_at.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(raw.expires_in ?? 3600)
        return AuthSession(accessToken: raw.access_token, refreshToken: raw.refresh_token, expiresAt: expires, user: raw.user.user)
    }

    private func send(_ path: String, query: [String: String] = [:], method: String = "POST", token: String? = nil,
                      json: [String: Any]? = nil, body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var c = URLComponents(url: config.url.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: c.url!, timeoutInterval: 20)
        request.httpMethod = method
        // The publishable key identifies the project; it is not a bearer token.
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        if let body { request.httpBody = body }
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    /// Auth errors are {"error_code", "msg"} (older: "error_description"); REST errors are
    /// {"code", "message"}.
    static func error(status: Int, data: Data) -> SupabaseError {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (o["msg"] ?? o["message"] ?? o["error_description"] ?? o["error"]) as? String
        let code = (o["error_code"] ?? o["code"] ?? o["error"]) as? String
        return SupabaseError(status: status, code: code, message: Self.friendly(message ?? "HTTP \(status)"))
    }

    /// Supabase's messages are written for developers; a few read better reworded.
    static func friendly(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("invalid login credentials") { return "That email and password do not match an account." }
        if m.contains("email not confirmed") { return "Confirm your email first: open the link we sent you." }
        if m.contains("user already registered") { return "That email already has an account. Sign in instead." }
        return message
    }
}

// Response shapes (snake_case, as Supabase sends them).

nonisolated private struct RawSession: Decodable {
    var access_token: String
    var refresh_token: String
    var expires_in: Double?
    var expires_at: Double?
    var user: RawUser
}

nonisolated private struct RawUser: Decodable {
    var id: String
    var email: String?
    var identities: [RawIdentity]?
    var app_metadata: RawAppMetadata?

    var user: AuthUser {
        var providers: [String] = []
        for p in identities?.map(\.provider) ?? app_metadata?.providers ?? [] where !providers.contains(p) { providers.append(p) }
        return AuthUser(id: id, email: email, providers: providers)
    }
}

nonisolated private struct RawIdentity: Decodable { var provider: String }
nonisolated private struct RawAppMetadata: Decodable { var providers: [String]? }
nonisolated private struct ProfileRow: Decodable { var display_name: String? }
