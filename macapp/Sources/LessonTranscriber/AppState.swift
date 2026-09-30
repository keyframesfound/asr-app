import AppKit
import Foundation
import SwiftUI
import LessonKit

/// Live transcription job state — the Mac equivalent of the web app's job
/// polling (stage text, percent, indeterminate flag, streaming segments).
@MainActor
final class JobState: ObservableObject {
    @Published var stage = "Queued"
    @Published var progress: Double = 0
    @Published var indeterminate = true
    @Published var segments: [TranscriptSegment] = []
    @Published var error: String?
    var startedAt = Date()
    var done = false

    var elapsedText: String {
        let s = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// App-wide state: the lesson list, the active transcription job, and the
/// summary / quiz / export actions. Replaces public/index.php's API handlers.
@MainActor
final class AppState: ObservableObject {
    @Published var lessons: [Lesson] = []
    @Published var selection: Lesson.ID?
    /// Settings is an in-app pane (sidebar item), not a separate window.
    @Published var showSettings = false
    @Published var job: JobState?
    /// Which lesson the active job belongs to.
    @Published var jobLessonID: String?

    // Per-lesson action state (web app: button spinners + status lines). Keyed
    // by lesson ID so a spinner or status line only ever shows on the lesson
    // that started the work — never bleeds onto other lesson pages.
    @Published var summaryBusyLessonIDs: Set<String> = []
    @Published var summaryErrors: [String: String] = [:]
    /// One quiz at a time: parallel first-time sign-ins would race for the
    /// single OAuth loopback port.
    @Published var quizBusyLessonID: String?
    @Published var quizStatuses: [String: String] = [:]
    @Published var quizErrors: [String: Bool] = [:]
    @Published var globalError: String?

    let settings: SettingsStore
    let googleAuth = GoogleAuthStore()
    let store: LessonStore
    private let engine = TranscriptionEngine.shared

    init(settings: SettingsStore, store: LessonStore) {
        self.settings = settings
        self.store = store
        lessons = store.loadAll()
        selection = lessons.first?.id
    }

    var selectedLesson: Lesson? {
        lessons.first(where: { $0.id == selection })
    }

    // MARK: - Import + transcription

    func importAndTranscribe(url: URL, audioLanguage: AudioLanguage, outputLanguage: OutputLanguage) {
        let filename = url.lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        guard allowedAudioExtensions.contains(ext) else {
            globalError = "Unsupported file type '.\(ext)'. Use MP3, WAV, M4A, AAC, OGG, FLAC or MP4."
            return
        }

        do {
            let (id, audioFile) = try store.importAudio(at: url, filename: filename)
            let lesson = Lesson(id: id, filename: filename,
                                audioLanguage: audioLanguage, outputLanguage: outputLanguage,
                                audioFile: audioFile)
            lessons.insert(lesson, at: 0)
            selection = lesson.id
            startTranscription(for: lesson)
        } catch {
            globalError = "Could not import the file: \(error.localizedDescription)"
        }
    }

    func startTranscription(for lesson: Lesson) {
        let job = JobState()
        self.job = job
        jobLessonID = lesson.id
        // The transcript is about to change — drop this lesson's stale statuses.
        quizStatuses[lesson.id] = nil
        quizErrors[lesson.id] = nil
        summaryErrors[lesson.id] = nil
        let audioURL = store.audioURL(for: lesson)
        let precision = EncoderPrecision(rawValue: UserDefaults.standard.string(forKey: "asr.precision") ?? "") ?? .fp16

        job.startedAt = Date()
        job.stage = "Starting…"
        job.indeterminate = true
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak job] _ in
            Task { @MainActor [weak job] in job?.objectWillChange.send() }
        }

        Task {
            defer { progressTimer.invalidate() }
            do {
                let segments = try await engine.transcribe(
                    url: audioURL,
                    language: lesson.audioLanguage,
                    precision: precision,
                    onUpdate: { [weak job] update in
                        Task { @MainActor [weak job] in
                            guard let job else { return }
                            if let error = update.error {
                                job.error = error
                            } else if let progress = update.progress {
                                job.indeterminate = false
                                job.progress = progress
                                job.stage = update.stage
                            } else {
                                job.indeterminate = true
                                job.stage = update.stage
                            }
                        }
                    },
                    onSegments: { [weak job] segments in
                        Task { @MainActor [weak job] in
                            job?.segments = segments
                        }
                    })
                finishTranscription(lessonID: lesson.id, segments: segments, job: job)
            } catch {
                job.indeterminate = false
                job.error = error.localizedDescription
            }
        }
    }

    private func finishTranscription(lessonID: String, segments: [TranscriptSegment], job: JobState) {
        guard let index = lessons.firstIndex(where: { $0.id == lessonID }) else { return }
        lessons[index].segments = segments
        try? store.save(lessons[index])
        job.done = true
        job.stage = "Done"
        job.progress = 100
        job.indeterminate = false
        // Hide the progress card shortly after completion, like the web app.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.job === job {
                self.job = nil
                self.jobLessonID = nil
            }
        }
    }

    // MARK: - AI summary (POST /api/summary equivalent)

    func summarize(_ lesson: Lesson) async {
        let transcript = lesson.transcriptText
        guard transcript.trimmingCharacters(in: .whitespaces).count >= 20 else {
            summaryErrors[lesson.id] = "Transcript is empty or too short to summarise."
            return
        }
        summaryBusyLessonIDs.insert(lesson.id)
        summaryErrors[lesson.id] = nil
        defer { summaryBusyLessonIDs.remove(lesson.id) }
        do {
            let client = OpenRouterClient(apiKey: BundledConfig.openRouterKey,
                                          model: BundledConfig.openRouterModel)
            let summary = try await client.summarize(
                transcript: transcript, lang: lesson.outputLanguage, length: settings.summaryLength)
            applySummary(lessonID: lesson.id, summary: summary)
        } catch {
            summaryErrors[lesson.id] = error.localizedDescription
        }
    }

    private func applySummary(lessonID: String, summary: String) {
        guard let index = lessons.firstIndex(where: { $0.id == lessonID }) else { return }
        lessons[index].summaryMarkdown = summary
        try? store.save(lessons[index])
    }

    // MARK: - Quiz + Google Form (POST /api/quiz + /api/forms equivalent)

    func makeQuiz(_ lesson: Lesson, count: Int) async {
        let transcript = lesson.transcriptText
        guard transcript.trimmingCharacters(in: .whitespaces).count >= 20 else {
            quizStatuses[lesson.id] = "Transcript is empty or too short to quiz on."
            quizErrors[lesson.id] = true
            return
        }
        guard quizBusyLessonID == nil else {
            quizStatuses[lesson.id] = "A quiz is already being generated — try again when it finishes."
            quizErrors[lesson.id] = true
            return
        }
        quizBusyLessonID = lesson.id
        quizErrors[lesson.id] = false
        quizStatuses[lesson.id] = "Generating questions…"
        defer { quizBusyLessonID = nil }
        do {
            let client = OpenRouterClient(apiKey: BundledConfig.openRouterKey,
                                          model: BundledConfig.openRouterModel)
            let questions = try await client.makeQuiz(
                transcript: transcript, lang: lesson.outputLanguage, count: count)
            // Same title/description the PHP front controller builds.
            let title = "\(lesson.displayName) — Quiz"
            let description = "Auto-generated quiz with \(questions.count) questions based on the session "
                + "recording '\(lesson.displayName)'. 1 point each."
            let quiz = try await uploadForm(lesson: lesson, title: title,
                                            description: description, questions: questions)
            applyQuiz(lessonID: lesson.id, quiz: quiz)
            quizStatuses[lesson.id] = "Done — \(quiz.questions.count)-question quiz created in your Google Drive. "
                + "Share the student link with your class."
        } catch {
            quizStatuses[lesson.id] = error.localizedDescription
            quizErrors[lesson.id] = true
        }
    }

    /// Uses the stored Google session; if the teacher has never signed in, the
    /// browser sign-in happens now and the session is kept for future quizzes.
    private func uploadForm(lesson: Lesson, title: String, description: String,
                            questions: [QuizQuestion]) async throws -> Quiz {
        let service = GoogleFormsService(credentials: .init(
            clientID: BundledConfig.googleClientID,
            clientSecret: BundledConfig.googleClientSecret))
        guard service.isConfigured else {
            throw GoogleFormsService.FormsError(
                "This copy of the app doesn't include Google sign-in credentials — contact the administrator.")
        }
        quizStatuses[lesson.id] = googleAuth.isSignedIn
            ? "Creating the form in your Google Drive…"
            : "Sign in with Google to create the quiz — approve it in your browser…"
        try await googleAuth.ensureSignedIn()
        let accessToken = try await googleAuth.validAccessToken()
        return try await service.createQuizForm(
            title: title, description: description, questions: questions, accessToken: accessToken)
    }

    private func applyQuiz(lessonID: String, quiz: Quiz) {
        guard let index = lessons.firstIndex(where: { $0.id == lessonID }) else { return }
        lessons[index].quiz = quiz
        try? store.save(lessons[index])
    }

    // MARK: - Exports + clipboard

    func exportDocx(kind: String, lesson: Lesson) {
        let text = kind == "transcript" ? lesson.transcriptText : (lesson.summaryMarkdown ?? "")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            globalError = kind == "summary" ? "Generate a summary first." : "Nothing to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = "\(lesson.exportBase)-\(kind).docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DocxWriter.build(kind: kind, text: text, title: lesson.displayName)
            try data.write(to: url, options: .atomic)
        } catch {
            globalError = "Word export failed: \(error.localizedDescription)"
        }
    }

    /// Share the lesson's Word files via the system share sheet.
    func shareLesson(_ lesson: Lesson) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LessonTranscriberShare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var items: [Any] = []
        if !lesson.segments.isEmpty, let data = try? DocxWriter.build(
            kind: "transcript", text: lesson.transcriptText, title: lesson.displayName) {
            let url = dir.appendingPathComponent("\(lesson.exportBase)-transcript.docx")
            if (try? data.write(to: url)) != nil { items.append(url) }
        }
        if let summary = lesson.summaryMarkdown, let data = try? DocxWriter.build(
            kind: "summary", text: summary, title: lesson.displayName) {
            let url = dir.appendingPathComponent("\(lesson.exportBase)-summary.docx")
            if (try? data.write(to: url)) != nil { items.append(url) }
        }
        guard !items.isEmpty else {
            globalError = "Nothing to share yet."
            return
        }
        let picker = NSSharingServicePicker(items: items)
        if let contentView = NSApp.keyWindow?.contentView {
            let anchor = CGRect(x: contentView.bounds.midX, y: contentView.bounds.midY,
                                width: 1, height: 1)
            picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
        }
    }

    // MARK: - Lesson management

    func rename(_ lesson: Lesson, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let index = lessons.firstIndex(where: { $0.id == lesson.id }) else { return }
        let ext = (lesson.audioFile as NSString).pathExtension
        lessons[index].filename = ext.isEmpty ? name : "\(name).\(ext)"
        try? store.save(lessons[index])
    }

    func deleteLesson(_ lesson: Lesson) {
        store.delete(lesson)
        lessons.removeAll(where: { $0.id == lesson.id })
        if selection == lesson.id { selection = lessons.first?.id }
        summaryBusyLessonIDs.remove(lesson.id)
        summaryErrors[lesson.id] = nil
        quizStatuses[lesson.id] = nil
        quizErrors[lesson.id] = nil
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showError(_ message: String) {
        globalError = message
    }
}
