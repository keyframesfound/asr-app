import Foundation
import SwiftUI

/// User preferences. Service credentials are baked into the app at build time
/// (BundledConfig) — the only thing teachers choose here is the summary length.
/// Google sign-in state lives in GoogleAuthStore (keychain).
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var summaryLength: SummaryLength {
        didSet { defaults.set(summaryLength.rawValue, forKey: "summary.length") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        summaryLength = SummaryLength(rawValue: defaults.string(forKey: "summary.length") ?? "") ?? .standard
    }

    /// The loopback redirect URI the Google OAuth client must whitelist.
    public static let googleRedirectURI = "http://127.0.0.1:8317/"
}
