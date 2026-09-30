import Foundation

/// Persistent Google sign-in state. The refresh token lives in the login
/// keychain; access tokens are refreshed transparently. Teachers sign in once
/// (from Settings, or on demand the first time they generate a quiz) and stay
/// signed in until they log out.
@MainActor
public final class GoogleAuthStore: ObservableObject {
    private static let keychainAccount = "google.tokens"

    private struct StoredTokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String?
    }

    @Published public private(set) var email: String?
    @Published public private(set) var busy = false
    @Published public var lastError: String?

    private var tokens: StoredTokens?

    public init() {
        restore()
    }

    public var isSignedIn: Bool { tokens != nil }

    private func restore() {
        guard let data = KeychainStore.getData(Self.keychainAccount),
              let stored = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return
        }
        tokens = stored
        email = stored.email
    }

    private func persist(_ tokens: StoredTokens) {
        self.tokens = tokens
        email = tokens.email
        if let data = try? JSONEncoder().encode(tokens) {
            KeychainStore.setData(data, for: Self.keychainAccount)
        }
    }

    /// Sign in via the browser. Replaces any existing session.
    public func signIn() async throws {
        let service = try service()
        busy = true
        defer { busy = false }
        do {
            let token = try await service.signIn()
            persist(StoredTokens(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: token.expiresAt,
                email: token.email))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Sign in only if there is no session yet — used by the quiz flow, so the
    /// first quiz asks for sign-in and later ones reuse it.
    public func ensureSignedIn() async throws {
        if tokens == nil {
            try await signIn()
        }
    }

    /// A usable access token, refreshing it when close to expiry. A failed
    /// refresh (revoked access, etc.) signs the user out.
    public func validAccessToken() async throws -> String {
        guard let tokens else {
            throw GoogleFormsService.FormsError("Not signed in to Google.")
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        let service = try service()
        do {
            let refreshed = try await GoogleFormsService.refresh(
                credentials: service.credentials, refreshToken: tokens.refreshToken)
            let updated = StoredTokens(
                accessToken: refreshed.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: Date().addingTimeInterval(Double(refreshed.expiresIn)),
                email: tokens.email)
            persist(updated)
            return updated.accessToken
        } catch {
            signOut()
            throw error
        }
    }

    public func signOut() {
        tokens = nil
        email = nil
        KeychainStore.delete(Self.keychainAccount)
    }

    private func service() throws -> GoogleFormsService {
        let service = GoogleFormsService(credentials: .init(
            clientID: BundledConfig.googleClientID,
            clientSecret: BundledConfig.googleClientSecret))
        guard service.isConfigured else {
            throw GoogleFormsService.FormsError(
                "This copy of the app doesn't include Google sign-in credentials — contact the administrator.")
        }
        return service
    }
}
