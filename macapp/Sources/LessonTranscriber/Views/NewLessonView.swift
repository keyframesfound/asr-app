import SwiftUI
import UniformTypeIdentifiers
import LessonKit

/// The import pane: drop zone, language rows, model-download hint.
/// Mirrors the top card of the web UI.
struct NewLessonView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var audioLanguage: AudioLanguage = .auto
    @State private var outputLanguage: OutputLanguage = .zhHK
    /// Shared with LessonDetailView's quiz button.
    @AppStorage("quizCount") private var quizCount = 10
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcriber")
                    .font(.largeTitle.bold())
                Text("Drop a session recording → transcription runs locally on this Mac's Neural Engine → AI summary & Google Form quiz below.")
                    .foregroundStyle(.secondary)
                Divider()
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    dropZone

                    SectionLabel("Options")
                    RowCard {
                        SettingRow(
                            title: "Session audio",
                            subtitle: "Language spoken in the recording",
                            showsDivider: true)
                        {
                            Picker("", selection: $audioLanguage) {
                                ForEach(AudioLanguage.allCases) { lang in
                                    Text(lang.label).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }

                        SettingRow(
                            title: "Summary & quiz language",
                            subtitle: "Language for the AI summary and the quiz",
                            showsDivider: true)
                        {
                            Picker("", selection: $outputLanguage) {
                                ForEach(OutputLanguage.allCases) { lang in
                                    Text(lang.label).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }

                        SettingRow(
                            title: "Quiz length",
                            subtitle: "Number of questions per generated quiz")
                        {
                            Picker("", selection: $quizCount) {
                                Text("5 questions").tag(5)
                                Text("10 questions").tag(10)
                                Text("15 questions").tag(15)
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }

                    if !TranscriptionEngine.modelsDownloaded(precision: .int8) {
                        Label("First transcription downloads the SenseVoice model (about 250 MB, once). "
                              + "Everything after that runs fully offline.", systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }

                Text("Transcription: audio is processed entirely on this Mac (Apple Neural Engine). "
                     + "Summaries & quizzes: transcript text is sent to OpenRouter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { Color.hexBackground.ignoresSafeArea() }
        // New lessons start from the Settings defaults; the pickers above stay
        // per-lesson and never write back.
        .onAppear {
            audioLanguage = settings.audioLanguage
            outputLanguage = settings.outputLanguage
        }
        .onChange(of: settings.audioLanguage) { _, new in audioLanguage = new }
        .onChange(of: settings.outputLanguage) { _, new in outputLanguage = new }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.importAndTranscribe(url: url, audioLanguage: audioLanguage,
                                          outputLanguage: outputLanguage)
            }
        }
    }

    static let importTypes: [UTType] = [.audio, .movie]

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("**Drop an audio file here** or")
                .foregroundStyle(.secondary)
            Button("Browse…") { showImporter = true }
                .buttonStyle(HexPrimaryButtonStyle())
            Text("MP3 · WAV · M4A · AAC · OGG · FLAC · MP4")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .background(isTargeted ? Color.hexSelected : Color.hexCard)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.white.opacity(0.45) : Color.hexBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { showImporter = true }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    state.importAndTranscribe(url: url, audioLanguage: audioLanguage,
                                              outputLanguage: outputLanguage)
                }
            }
            return true
        }
    }
}
