import CryptoKit
import Foundation
import Security

/// Values both targets read from their Info.plist. They come from `Config/*.xcconfig`.
public enum AppConfig {
    public static var appGroup: String { value("OpenGDriveAppGroup") }
    public static var keychainGroup: String { value("OpenGDriveKeychainGroup") }
    public static var oauthClientID: String { value("OpenGDriveOAuthClientID") }

    public static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static var sharedContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static let pausedKey = "paused"

    /// While paused the extension reports the server as unreachable, so nothing moves in either direction.
    public static var paused: Bool {
        get { sharedDefaults?.bool(forKey: pausedKey) ?? false }
        set { sharedDefaults?.set(newValue, forKey: pausedKey) }
    }

    private static func value(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}

/// OAuth tokens for one Google account.
public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiry: Date

    public init(accessToken: String, refreshToken: String, expiry: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }
}

/// Keeps the credentials in the data protection Keychain, shared by the app and the extension.
public struct CredentialStore: Sendable {
    public let service = "OpenGDrive"
    public let account = "google"
    public let accessGroup: String

    public init(accessGroup: String = AppConfig.keychainGroup) {
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if !accessGroup.isEmpty { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> Credentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials) throws {
        delete()
        var q = baseQuery
        q[kSecValueData as String] = try JSONEncoder().encode(credentials)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not save the Google sign-in to the Keychain (\(status))",
            ])
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Google's OAuth flow for installed apps, with PKCE and no client secret. Uses an OAuth client of
/// type "iOS", whose redirect is the reversed client ID, so `ASWebAuthenticationSession` can catch it.
public struct GoogleOAuth: Sendable {
    public static let scope = "https://www.googleapis.com/auth/drive"
    static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    public let clientID: String
    private let session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    /// `1234-abc.apps.googleusercontent.com` becomes `com.googleusercontent.apps.1234-abc`.
    public var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    /// A fresh PKCE verifier and state for one sign-in attempt.
    public struct Attempt: Sendable {
        public let verifier: String
        public let state: String

        public init() {
            verifier = Self.random(48)
            state = Self.random(16)
        }

        var challenge: String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        }

        private static func random(_ bytes: Int) -> String {
            var data = Data(count: bytes)
            _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
            return data.base64URL
        }
    }

    public func authorizationURL(for attempt: Attempt) -> URL {
        var comps = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: attempt.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: attempt.state),
            // Offline access plus consent makes Google return a refresh token every time.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    /// Turns the redirect Google sent back into credentials.
    public func finish(callback: URL, attempt: Attempt) async throws -> Credentials {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw DriveAPIError(.unauthorized, "Google sign-in failed: \(error)") }
        guard value("state") == attempt.state, let code = value("code") else {
            throw DriveAPIError(.unauthorized, "Google sign-in returned an unexpected answer. Try again.")
        }
        let reply = try await token([
            "client_id": clientID,
            "code": code,
            "code_verifier": attempt.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refresh = reply.refresh_token else {
            throw DriveAPIError(.unauthorized, "Google didn't return a refresh token. Remove the app's access in your Google account and sign in again.")
        }
        return Credentials(accessToken: reply.access_token, refreshToken: refresh, expiry: Date().addingTimeInterval(reply.expires_in))
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        let reply = try await token([
            "client_id": clientID,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token",
        ])
        return Credentials(
            accessToken: reply.access_token,
            refreshToken: reply.refresh_token ?? credentials.refreshToken,
            expiry: Date().addingTimeInterval(reply.expires_in)
        )
    }

    private struct TokenReply: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
    }

    private func token(_ form: [String: String]) async throws -> TokenReply {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw DriveAPIError(.transport, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // invalid_grant means the refresh token was revoked or expired.
            let kind: DriveAPIError.Kind = (400..<500).contains(status) ? .unauthorized : .server
            throw DriveAPIError(kind, "Google token request failed (\(status)): \(String(decoding: data, as: UTF8.self))")
        }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }
}

/// Hands out a valid access token, refreshing it and saving the result when it's about to expire.
public actor TokenProvider {
    private var credentials: Credentials?
    private let oauth: GoogleOAuth
    private let store: CredentialStore

    public init(oauth: GoogleOAuth, store: CredentialStore = CredentialStore()) {
        self.oauth = oauth
        self.store = store
        credentials = store.read()
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        // The other process may have refreshed in the meantime.
        if let saved = store.read(), saved != credentials { credentials = saved }
        guard let current = credentials else { throw DriveAPIError(.unauthorized, DriveError.notSignedIn.description) }
        if !forceRefresh, current.expiry > Date().addingTimeInterval(60) { return current.accessToken }
        let fresh = try await oauth.refresh(current)
        credentials = fresh
        try? store.save(fresh)
        return fresh.accessToken
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
