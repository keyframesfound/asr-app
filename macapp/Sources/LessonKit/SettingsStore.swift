import Foundation
import SwiftUI

/// User preferences. Service credentials are baked into the app at build time
/// (BundledConfig) — the choices here are the AI defaults (summary style and
/// length, AI language, quiz length) and the session audio language, all
/// overridable per lesson on import. Google sign-in state lives in
/// GoogleAuthStore (keychain).
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var summaryLength: SummaryLength {
        didSet { defaults.set(summaryLength.rawValue, forKey: "summary.length") }
    }

    @Published public var summaryStyle: SummaryStyle {
        didSet { defaults.set(summaryStyle.rawValue, forKey: "summary.style") }
    }

    /// Language the AI summary and quiz are written in (default for new lessons).
    @Published public var outputLanguage: OutputLanguage {
        didSet { defaults.set(outputLanguage.rawValue, forKey: "output.language") }
    }

    /// Language spoken in new recordings (default for new lessons).
    @Published public var audioLanguage: AudioLanguage {
        didSet { defaults.set(audioLanguage.rawValue, forKey: "audio.language") }
    }

    /// Number of questions per generated quiz. Shares the "quizCount" default
    /// with the New Lesson pane and the quiz button (@AppStorage).
    @Published public var quizCount: Int {
        didSet { defaults.set(quizCount, forKey: "quizCount") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        summaryLength = SummaryLength(rawValue: defaults.string(forKey: "summary.length") ?? "") ?? .standard
        summaryStyle = SummaryStyle(rawValue: defaults.string(forKey: "summary.style") ?? "") ?? .lesson
        outputLanguage = OutputLanguage(rawValue: defaults.string(forKey: "output.language") ?? "") ?? .zhHK
        audioLanguage = AudioLanguage(rawValue: defaults.string(forKey: "audio.language") ?? "") ?? .auto
        let storedCount = defaults.object(forKey: "quizCount") as? Int ?? QuizLength.ten.rawValue
        quizCount = QuizLength(rawValue: storedCount)?.rawValue ?? QuizLength.ten.rawValue
    }

    /// The loopback redirect URI the Google OAuth client must whitelist.
    public static let googleRedirectURI = "http://127.0.0.1:8317/"
}
