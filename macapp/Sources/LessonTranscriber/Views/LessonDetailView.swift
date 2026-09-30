import AppKit
import SwiftUI
import LessonKit

/// A lesson's transcript, summary, quiz and exports — the lower half of the
/// web UI (transcript card, actions, summary card, quiz card).
struct LessonDetailView: View {
    @EnvironmentObject var state: AppState
    /// Shared with the import pane's "Quiz length" picker.
    @AppStorage("quizCount") private var quizCount = 10
    let lesson: Lesson

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if isCurrentJob, let job = state.job {
                    ProgressCard(job: job)
                    if let error = job.error {
                        errorBanner(error)
                    }
                }

                transcriptCard
                actionsCard

                if state.summaryBusyLessonIDs.contains(lesson.id) || lesson.summaryMarkdown != nil
                    || state.summaryErrors[lesson.id] != nil {
                    summaryCard
                }
                if state.quizBusyLessonID == lesson.id || lesson.quiz != nil
                    || !(state.quizStatuses[lesson.id] ?? "").isEmpty {
                    quizCard
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { Color.hexBackground.ignoresSafeArea() }
    }

    private var isCurrentJob: Bool {
        state.job != nil && state.jobLessonID == lesson.id
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lesson.displayName)
                .font(.largeTitle.bold())
                .lineLimit(1)
            Text(meta)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.top, 4)
        }
    }

    private var meta: String {
        let date = lesson.createdAt.formatted(date: .abbreviated, time: .shortened)
        var parts = [date, "Audio: \(lesson.audioLanguage.label)"]
        if lesson.duration > 0 {
            parts.insert("Duration \(Lesson.formatTimestamp(lesson.duration))", at: 1)
        }
        return parts.joined(separator: " · ")
    }

    private var transcriptCard: some View {
        Card {
            SectionHead(
                title: "Transcript",
                subtitle: lesson.segments.isEmpty
                    ? nil
                    : "\(lesson.segments.count) segments · \(Lesson.formatTimestamp(lesson.duration))")
            {
                Button {
                    state.exportDocx(kind: "transcript", lesson: lesson)
                } label: {
                    Label("Word", systemImage: "arrow.down.doc")
                }
                .buttonStyle(HexButtonStyle())
                .disabled(lesson.segments.isEmpty)
                Button {
                    state.copyToClipboard(lesson.transcriptText)
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .buttonStyle(HexButtonStyle())
                .disabled(lesson.segments.isEmpty)
                Button {
                    state.shareLesson(lesson)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(HexButtonStyle())
                .disabled(lesson.segments.isEmpty)
            }

            if lesson.segments.isEmpty && !isCurrentJob {
                Text("No transcript yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(displaySegments.enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .firstTextBaseline) {
                                Text(Lesson.formatTimestamp(segment.start))
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                                Text(segment.text)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 340)
            }
        }
    }

    /// While transcribing, show the live segments from the job so the
    /// transcript builds up; afterwards the saved lesson's segments.
    private var displaySegments: [TranscriptSegment] {
        if isCurrentJob, let job = state.job, !job.segments.isEmpty {
            return job.segments
        }
        return lesson.segments
    }

    private var actionsCard: some View {
        Card {
            HStack(spacing: 12) {
                Button {
                    Task { await state.summarize(lesson) }
                } label: {
                    Label("AI Summary", systemImage: "sparkles")
                }
                .buttonStyle(HexPrimaryButtonStyle())
                .disabled(lesson.segments.count < 2 || state.summaryBusyLessonIDs.contains(lesson.id))

                Button {
                    Task { await state.makeQuiz(lesson, count: quizCount) }
                } label: {
                    Label("Generate Google Form Quiz", systemImage: "list.clipboard")
                }
                .buttonStyle(HexPrimaryButtonStyle())
                .disabled(lesson.segments.count < 2 || state.quizBusyLessonID == lesson.id)

                if state.summaryBusyLessonIDs.contains(lesson.id) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Summarising…")
                        .foregroundStyle(.secondary)
                }
                if state.quizBusyLessonID == lesson.id {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private var summaryCard: some View {
        Card {
            SectionHead(title: "AI Summary", subtitle: "Generated from the transcript") {
                Button {
                    state.exportDocx(kind: "summary", lesson: lesson)
                } label: {
                    Label("Word", systemImage: "arrow.down.doc")
                }
                .buttonStyle(HexButtonStyle())
                .disabled(lesson.summaryMarkdown == nil)
                Button {
                    if let summary = lesson.summaryMarkdown {
                        state.copyToClipboard(summary)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(HexButtonStyle())
                .disabled(lesson.summaryMarkdown == nil)
            }
            if let error = state.summaryErrors[lesson.id] {
                errorBanner(error)
            }
            if state.summaryBusyLessonIDs.contains(lesson.id) {
                Text("Working on it — this takes a few seconds…")
                    .foregroundStyle(.secondary)
            } else if let summary = lesson.summaryMarkdown {
                MarkdownText(markdown: summary)
            }
        }
    }

    private var quizCard: some View {
        Card {
            SectionHead(title: "Google Form Quiz") {
                if let quiz = lesson.quiz, let formURL = quiz.formURL, !formURL.isEmpty {
                    Button {
                        state.copyToClipboard(formURL)
                    } label: {
                        Label("Copy student link", systemImage: "link")
                    }
                    .buttonStyle(HexButtonStyle())
                    Button {
                        if let url = URL(string: formURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("Open quiz form", systemImage: "square.and.arrow.up.on.square")
                    }
                    .buttonStyle(HexButtonStyle())
                    Button {
                        if let edit = quiz.formEditURL, let url = URL(string: edit) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Edit form", systemImage: "pencil")
                    }
                    .buttonStyle(HexButtonStyle())
                }
            }

            if let status = state.quizStatuses[lesson.id], !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(state.quizErrors[lesson.id] == true ? Color.red : .secondary)
            }

            if let quiz = lesson.quiz {
                if let formURL = quiz.formURL, let url = URL(string: formURL) {
                    Link("Student link: \(formURL)", destination: url)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                QuizPreview(quiz: quiz)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

/// The generated questions, collapsible so the card stays compact.
struct QuizPreview: View {
    let quiz: Quiz
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("\(quiz.questions.count) questions") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(quiz.questions) { question in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.question)
                            .font(.callout.weight(.medium))
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            HStack(alignment: .top, spacing: 4) {
                                Text(index == question.answer ? "●" : "○")
                                    .foregroundStyle(index == question.answer ? Color.accentColor : Color.secondary)
                                Text(option)
                            }
                            .font(.callout)
                        }
                        if !question.explanation.isEmpty {
                            Text(question.explanation)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }
}
