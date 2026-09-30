import Foundation
import FluidAudio

/// Stage/progress update. `progress == nil` means indeterminate (animated bar),
/// exactly like the web app's job polling (`indeterminate` flag).
public struct StageUpdate: Sendable {
    public var stage: String
    public var progress: Double?
    public var error: String?

    public init(stage: String, progress: Double? = nil, error: String? = nil) {
        self.stage = stage
        self.progress = progress
        self.error = error
    }
}

/// Local transcription pipeline: audio file → Silero VAD → SenseVoice-Small.
///
/// Same pipeline shape as the PHP app's Python sidecar (asr-service/): speech
/// segments are merged into chunks of at most 25 s (bridging gaps under 0.8 s),
/// each chunk transcribed with inverse text normalisation, timestamps stitched
/// onto one timeline, and progress reported per chunk.
///
/// Everything runs on-device on Apple Silicon: the SenseVoice encoder runs on
/// the Apple Neural Engine through Core ML (FluidAudio), the VAD runs on CPU.
public final class TranscriptionEngine: @unchecked Sendable {
    public static let shared = TranscriptionEngine()

    private let lock = NSLock()
    private var models: SenseVoiceModels?
    private var managers: [AudioLanguage: SenseVoiceManager] = [:]
    private var loadedPrecision: SenseVoiceEncoderPrecision?

    /// VAD segments are merged into chunks of at most this length (sidecar: MAX_CHUNK_MS).
    private static let maxChunkSeconds = 25.0
    /// Gaps shorter than this are bridged inside a chunk (sidecar: MAX_GAP_MS).
    private static let maxGapSeconds = 0.8

    public init() {}

    // MARK: - Model loading

    /// Load (downloading on first use) the SenseVoice models. Downloads report
    /// progress; loads are cached for the process lifetime.
    public func loadModels(
        precision: EncoderPrecision,
        onProgress: @escaping @Sendable (StageUpdate) -> Void
    ) async throws -> SenseVoiceModels {
        let coreMLPrecision: SenseVoiceEncoderPrecision = precision == .int8 ? .int8 : .fp16
        if let cached = cachedModels(coreMLPrecision) { return cached }

        onProgress(StageUpdate(stage: "Loading speech model…", progress: 5))
        let loaded = try await SenseVoiceModels.downloadAndLoad(precision: coreMLPrecision) { download in
            // Model download/preparation maps onto the 0–5% head of the bar.
            let percent = download.fractionCompleted * 5
            let phase: String
            switch download.phase {
            case .listing: phase = "Finding model files…"
            case .compiling(let name): phase = "Preparing model (\(name))…"
            case .downloading(let done, let total): phase = "Downloading speech model… \(done)/\(total)"
            }
            onProgress(StageUpdate(stage: phase, progress: percent))
        }

        storeModels(loaded, precision: coreMLPrecision)
        return loaded
    }

    private func cachedModels(_ precision: SenseVoiceEncoderPrecision) -> SenseVoiceModels? {
        lock.lock()
        defer { lock.unlock() }
        guard let models, loadedPrecision == precision else { return nil }
        return models
    }

    private func storeModels(_ models: SenseVoiceModels, precision: SenseVoiceEncoderPrecision) {
        lock.lock()
        defer { lock.unlock() }
        self.models = models
        managers = [:]
        loadedPrecision = precision
    }

    /// One SenseVoiceManager per language — the language embedding is a fixed
    /// encoder input, baked in at init. Managers are cheap (they share the
    /// loaded MLModels); only the embed index differs.
    public func manager(for language: AudioLanguage, models: SenseVoiceModels) -> SenseVoiceManager {
        lock.lock()
        defer { lock.unlock() }
        if let manager = managers[language] { return manager }
        // textnorm 14 = withitn, the same inverse-text-normalisation the
        // sidecar enables (use_itn=True / textnorm="withitn").
        let manager = SenseVoiceManager(models: models, language: language.embedIndex, textNorm: 14)
        managers[language] = manager
        return manager
    }

    /// True when the SenseVoice artifacts are already on disk (the UI shows a
    /// "first run downloads the model" hint otherwise).
    public static func modelsDownloaded(precision: EncoderPrecision) -> Bool {
        let coreMLPrecision: SenseVoiceEncoderPrecision = precision == .int8 ? .int8 : .fp16
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let dir = appSupport
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent("sensevoice-small-coreml", isDirectory: true)
        return SenseVoiceModels.modelsExist(at: dir, precision: coreMLPrecision)
    }

    // MARK: - Pipeline

    /// Transcribe a lesson recording. `onSegments` streams partial results as
    /// chunks complete so the transcript builds up live.
    public func transcribe(
        url: URL,
        language: AudioLanguage,
        precision: EncoderPrecision,
        onUpdate: @escaping @Sendable (StageUpdate) -> Void,
        onSegments: @escaping @Sendable ([TranscriptSegment]) -> Void
    ) async throws -> [TranscriptSegment] {
        onUpdate(StageUpdate(stage: "Converting audio…", progress: 2))
        let samples = try await Task.detached(priority: .userInitiated) {
            try Self.decodeTo16kMono(url: url)
        }.value

        let models = try await loadModels(precision: precision, onProgress: onUpdate)

        onUpdate(StageUpdate(stage: "Detecting speech segments…", progress: 8))
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
        var segmentation = VadSegmentationConfig.default
        segmentation.minSpeechDuration = 0.25
        segmentation.minSilenceDuration = 0.4
        segmentation.speechPadding = 0.12
        let speechSegments = try await vad.segmentSpeech(samples, config: segmentation)
        guard !speechSegments.isEmpty else {
            throw TranscriptionError("No speech detected in the audio file.")
        }
        let chunks = Self.mergeChunks(speechSegments.map { ($0.startTime, $0.endTime) })

        let asr = manager(for: language, models: models)
        let total = chunks.count
        var results = [TranscriptSegment?](repeating: nil, count: total)
        var done = 0

        // SenseVoiceManager is an actor: chunk calls serialise on it, which is
        // the right arrangement — the ANE is the bottleneck, not the host.
        for (index, (start, end)) in chunks.enumerated() {
            let from = min(Int(start * 16_000), samples.count)
            let to = min(Int(end * 16_000), samples.count)
            let slice = from < to ? Array(samples[from..<to]) : []
            if slice.isEmpty {
                results[index] = TranscriptSegment(start: start, end: end, text: "")
            } else {
                let text = try await asr.transcribe(audio: slice)
                results[index] = TranscriptSegment(start: start, end: end, text: text)
            }
            done += 1
            onUpdate(StageUpdate(stage: "Transcribing… \(done)/\(total)",
                                 progress: 10 + 88 * Double(done) / Double(total)))
            onSegments(results.compactMap { $0 }.filter { !$0.text.isEmpty })
        }

        let segments = results.compactMap { $0 }.filter { !$0.text.isEmpty }
        guard !segments.isEmpty else {
            throw TranscriptionError("Transcription produced no text for this audio.")
        }
        onUpdate(StageUpdate(stage: "Done", progress: 100))
        return segments
    }

    public struct TranscriptionError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    // MARK: - Audio decoding

    /// Any supported input → 16 kHz mono Float32 samples. AVFoundation handles
    /// MP3/WAV/M4A/AAC/FLAC/MP4 natively; OGG (and anything CoreAudio rejects)
    /// falls back to ffmpeg when it is installed — the sidecar required ffmpeg
    /// for everything, the app only needs it for OGG.
    public static func decodeTo16kMono(url: URL) throws -> [Float] {
        do {
            return try AudioConverter().resampleAudioFile(url)
        } catch {
            guard let ffmpeg = ffmpegPath() else {
                if url.pathExtension.lowercased() == "ogg" {
                    throw TranscriptionError(
                        "OGG needs ffmpeg for decoding — install it with `brew install ffmpeg`.")
                }
                throw TranscriptionError(
                    "Could not decode this audio file. Try re-exporting as MP3 or WAV.")
            }
            return try decodeWithFFmpeg(ffmpeg: ffmpeg, url: url)
        }
    }

    private static func ffmpegPath() -> String? {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func decodeWithFFmpeg(ffmpeg: String, url: URL) throws -> [Float] {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-i", url.path, "-ac", "1", "-ar", "16000", "-vn", out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError("ffmpeg failed to decode this audio file.")
        }
        return try AudioConverter().resampleAudioFile(out)
    }

    // MARK: - Chunking (port of the sidecar's _merge_chunks)

    public static func mergeChunks(_ segments: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var chunks: [(Double, Double)] = []
        var current: (Double, Double)?
        for (start, end) in segments {
            if current == nil {
                current = (start, end)
            } else if end - current!.0 <= maxChunkSeconds && start - current!.1 <= maxGapSeconds {
                current!.1 = end
            } else {
                chunks.append(current!)
                current = (start, end)
            }
        }
        if let current { chunks.append(current) }
        return chunks
    }
}
