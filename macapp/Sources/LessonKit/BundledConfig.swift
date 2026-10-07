import Foundation

/// Pre-configured service credentials, baked into the app at build time.
///
/// Scripts/build_app.sh copies the repo's .env values (OpenRouter key + model,
/// Google OAuth client) into `Contents/Resources/config.plist`, so teachers
/// never configure anything. In development the package falls back to reading
/// the repo .env directly. Secrets ship inside the bundle — fine for internal
/// school distribution, never for the App Store or public releases.
public enum BundledConfig {
    public static let values: [String: String] = load()

    public static var openRouterKey: String { values["OPENROUTER_API_KEY"] ?? "" }
    public static var openRouterModel: String {
        let model = values["OPENROUTER_MODEL"] ?? ""
        return model.isEmpty ? "deepseek/deepseek-v4-pro" : model
    }
    public static var googleClientID: String { values["GOOGLE_CLIENT_ID"] ?? "" }
    public static var googleClientSecret: String { values["GOOGLE_CLIENT_SECRET"] ?? "" }
    /// GitHub "owner/repo" whose Releases feed the in-app updater (AppUpdater).
    public static var githubRepo: String { values["GITHUB_REPO"] ?? "" }

    private static func load() -> [String: String] {
        let keys = ["OPENROUTER_API_KEY", "OPENROUTER_MODEL",
                    "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GITHUB_REPO"]

        // 1. The app bundle's config.plist (release builds).
        if let url = Bundle.main.url(forResource: "config", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url) as? [String: String],
           dict["OPENROUTER_API_KEY"]?.isEmpty == false {
            return dict
        }

        // 2. Development: the repo .env when running from the package tree.
        for candidate in ["../.env", ".env"] {
            guard let text = try? String(contentsOfFile: candidate, encoding: .utf8) else { continue }
            var dict: [String: String] = [:]
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") || line.isEmpty { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                dict[key] = value
            }
            let found = dict.filter { keys.contains($0.key) && !$0.value.isEmpty }
            if !found.isEmpty { return found }
        }
        return [:]
    }
}
