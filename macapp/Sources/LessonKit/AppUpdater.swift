import Foundation
import AppKit

/// In-app updater backed by GitHub Releases. On launch (and via "Check for
/// Updates") it asks api.github.com for the repo's latest release; when the
/// tag is newer than the running version it offers a one-click update:
/// download the release's app zip, unpack it, then a tiny helper script waits
/// for the app to quit, swaps the bundle in place and relaunches.
///
/// No Sparkle, no appcast — publishing an update is just attaching the zip
/// that Scripts/build_app.sh produces to a GitHub release (Scripts/release.sh
/// does the whole thing). The repo slug is baked into config.plist at build
/// time (GITHUB_REPO, taken from the git remote); dev builds fall back to the
/// constant below. The repo must be public — the API is queried without a
/// token.
@MainActor
public final class AppUpdater: ObservableObject {
    /// Fallback when the bundle carries no GITHUB_REPO (dev runs, SKIP_CONFIG).
    private static let fallbackRepo = "keyframesfound/asr-web"

    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(Double) // 0...1
        case readyToInstall(AppRelease)
        case failed(String)
    }

    public struct AppRelease: Equatable {
        public let version: String // "1.2.0" — the tag without its leading v
        public let title: String
        public let notes: String // markdown from the release body
        public let pageURL: URL
        public let zipURL: URL? // nil → release only ships a .dmg; open the page instead
        public let zipSize: Int64
    }

    public enum UpdateError: LocalizedError {
        case message(String)
        public var errorDescription: String? { switch self { case .message(let m): return m } }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: "updates.autoCheck") }
    }

    public let currentVersion: String
    private let repo: String
    private let defaults: UserDefaults
    private var stagedApp: URL?
    private var pendingRelease: AppRelease?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.repo = BundledConfig.githubRepo.isEmpty ? Self.fallbackRepo : BundledConfig.githubRepo
        self.currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        self.autoCheck = defaults.object(forKey: "updates.autoCheck") as? Bool ?? true
    }

    // MARK: - Status for the UI

    /// A newer release has been found (drives the sidebar pill).
    public var updateAvailable: Bool {
        switch phase {
        case .available, .downloading, .readyToInstall: return true
        default: return false
        }
    }

    public var updateVersion: String? {
        switch phase {
        case .available(let release), .readyToInstall(let release): return release.version
        case .downloading: return pendingRelease?.version
        default: return nil
        }
    }

    public var busy: Bool {
        switch phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    // MARK: - Checking

    /// Called once when the main window appears — honours the toggle and a
    /// 12-hour cadence so we don't ping GitHub on every open.
    public func startupCheckIfNeeded() async {
        guard autoCheck else { return }
        let last = defaults.double(forKey: "updates.lastCheck")
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        await checkForUpdates(manual: false)
    }

    public func checkForUpdates(manual: Bool) async {
        guard !busy else { return }
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            defaults.set(Date().timeIntervalSince1970, forKey: "updates.lastCheck")
            guard let release else {
                phase = manual ? .failed("No releases published yet at github.com/\(repo).") : .idle
                return
            }
            if Self.isNewer(release.version, than: currentVersion) {
                pendingRelease = release
                phase = .available(release)
            } else {
                phase = manual ? .upToDate : .idle
            }
        } catch {
            // The automatic launch check fails silently (offline, rate limit);
            // only a manual check surfaces the error.
            phase = manual ? .failed("Could not check for updates: \(error.localizedDescription)") : .idle
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let assets: [GitHubAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body
            case htmlURL = "html_url", assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    private func fetchLatestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Transcriber/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw UpdateError.message("GitHub returned an unexpected response.")
        }
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Prefer the app zip (Scripts/build_app.sh names it "App-Version.zip");
        // fall back to any zip. A .dmg can't be swapped in automatically — the
        // release page opens instead.
        let appKey = Self.normalizeKey(
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Transcriber")
        let zips = decoded.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let asset = zips.first { Self.normalizeKey($0.name).contains(appKey) } ?? zips.first

        return AppRelease(
            version: Self.parseVersionText(decoded.tagName),
            title: decoded.name ?? decoded.tagName,
            notes: decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: URL(string: decoded.htmlURL) ?? URL(string: "https://github.com/\(repo)/releases")!,
            zipURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            zipSize: asset?.size ?? 0)
    }

    // MARK: - Download & unpack

    public func downloadUpdate() async {
        guard case .available(let release) = phase, let zipURL = release.zipURL else { return }
        phase = .downloading(0)
        do {
            let zip = try await Self.download(zipURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            }
            phase = .downloading(1)
            let staged = try Self.unpack(zip: zip, expectedVersion: release.version,
                                         expectedBundleID: Bundle.main.bundleIdentifier)
            stagedApp = staged
            phase = .readyToInstall(release)
        } catch {
            phase = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    /// Session download with byte progress; the delegate is retained by the
    /// session until it invalidates itself on completion.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let progress: @Sendable (Double) -> Void
        private let continuation: CheckedContinuation<URL, Error>
        private weak var session: URLSession?
        private var finished = false

        init(progress: @escaping @Sendable (Double) -> Void,
             continuation: CheckedContinuation<URL, Error>) {
            self.progress = progress
            self.continuation = continuation
        }

        func attach(session: URLSession) { self.session = session }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("update-\(UUID().uuidString).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                finish(.success(dest))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func finish(_ result: Result<URL, Error>) {
            guard !finished else { return }
            finished = true
            session?.finishTasksAndInvalidate()
            continuation.resume(with: result)
        }
    }

    nonisolated private static func download(_ url: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = DownloadDelegate(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            delegate.attach(session: session)
            session.downloadTask(with: url).resume()
        }
    }

    /// ditto-unzips the release archive and returns the .app inside — after
    /// checking it really is this app and the version the release claims.
    /// These guards run before anything touches the installed bundle.
    nonisolated private static func unpack(zip: URL, expectedVersion: String,
                                           expectedBundleID: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, dir.path]
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.message("Could not unpack the update archive. "
                + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The bundle sits at the top level (--keepParent), but tolerate one
        // folder deep in case the archive is wrapped.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var candidates = contents.filter { $0.pathExtension == "app" }
        if candidates.isEmpty {
            for child in contents
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let nested = (try? FileManager.default.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                candidates += nested.filter { $0.pathExtension == "app" }
            }
        }
        guard let app = candidates.first else {
            throw UpdateError.message("The release archive does not contain an app bundle.")
        }

        let info = Bundle(url: app)?.infoDictionary
        if let expectedBundleID, let newID = info?["CFBundleIdentifier"] as? String, newID != expectedBundleID {
            throw UpdateError.message("The downloaded bundle is \(newID), not \(expectedBundleID) "
                + "— refusing to replace the app.")
        }
        let newVersion = (info?["CFBundleShortVersionString"] as? String) ?? ""
        if parseVersion(newVersion) != parseVersion(expectedVersion) {
            throw UpdateError.message("The downloaded app reports version \(newVersion), but the release is "
                + "\(expectedVersion) — rebuild with VERSION=\(expectedVersion).")
        }
        return app
    }

    // MARK: - Install (swap + relaunch)

    /// Swaps in the staged update: writes a helper script that waits for this
    /// app to quit, replaces the bundle and relaunches — then quits the app.
    public func installAndRestart() {
        guard case .readyToInstall = phase, let staged = stagedApp else { return }
        let target = Bundle.main.bundleURL
        if let blocker = Self.installBlocker(target: target) {
            phase = .failed(blocker)
            return
        }
        do {
            let script = try Self.writeInstallScript(target: target, staged: staged)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script.path]
            try proc.run() // detached on purpose — the app terminates right after
        } catch {
            phase = .failed("Could not start the update: \(error.localizedDescription)")
            return
        }
        phase = .idle
        NSApplication.shared.terminate(nil)
    }

    private nonisolated static func installBlocker(target: URL) -> String? {
        guard target.pathExtension == "app", target.pathComponents.count > 2 else {
            return "The app is running from an unexpected location (\(target.path)) — refusing to replace it. "
                + "Run the installed copy (e.g. from /Applications)."
        }
        guard !target.path.contains("'") else {
            return "The app path contains a quote character — refusing to script the replacement."
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            return "No permission to replace the app at \(target.path). Move it to /Applications and try again."
        }
        return nil
    }

    private nonisolated static func writeInstallScript(target: URL, staged: URL) throws -> URL {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("update-install.log")
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/bash
        # Swaps in the Transcriber update once the running app has quit. Installs
        # under the staged bundle's own name, so an app rename ships cleanly —
        # the old-named bundle is removed after the new one is in place.
        TARGET='\(target.path)'
        NEW='\(staged.path)'
        FINAL="$(dirname "$TARGET")/$(basename "$NEW")"
        LOG='\(log.path)'
        {
          echo "[$(date)] update: installing from $NEW"
          for i in $(seq 1 200); do
            pgrep -f "$TARGET" >/dev/null 2>&1 || break
            sleep 0.3
          done
          if pgrep -f "$TARGET" >/dev/null 2>&1; then
            echo "error: the app was still running after 60s"
            exit 1
          fi
          rm -rf "$FINAL" || exit 1
          mv "$NEW" "$FINAL" || exit 1
          if [ "$FINAL" != "$TARGET" ]; then
            rm -rf "$TARGET"
            echo "[$(date)] update: removed the old bundle $TARGET"
          fi
          echo "[$(date)] replaced, relaunching"
          open "$FINAL"
        } >> "$LOG" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: - Misc

    public func openReleasesPage() {
        let url: URL
        if case .available(let release) = phase, release.zipURL == nil {
            url = release.pageURL
        } else {
            url = URL(string: "https://github.com/\(repo)/releases")!
        }
        NSWorkspace.shared.open(url)
    }

    /// "v1.2.0" / "1.2.0" / "1.2" / "1.2.0-rc1" → comparable numbers.
    nonisolated static func parseVersion(_ string: String) -> [Int] {
        var text = parseVersionText(string)
        return text.split(separator: ".").map {
            Int($0.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0
        }
    }

    /// The bare version text of a tag: "v1.2.0-rc1" → "1.2.0".
    nonisolated static func parseVersionText(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        return text
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = parseVersion(candidate)
        let old = parseVersion(current)
        for i in 0 ..< max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// "Transcriber-1.3.0.zip" → "transcriber130" (asset matching).
    nonisolated private static func normalizeKey(_ string: String) -> String {
        string.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
