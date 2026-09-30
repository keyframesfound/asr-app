import Foundation

/// One timestamped transcript line — the same shape the PHP app's jobs store
/// (`{start, end, text}` seconds) and the sidecar produce.
public struct TranscriptSegment: Codable, Hashable, Identifiable {
    public var start: Double
    public var end: Double
    public var text: String

    public var id: String { "\(start)-\(end)-\(hashValue)" }

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Lesson-audio language for SenseVoice. `embedIndex` is the model's language
/// embedding id (FunASR SenseVoiceSmall: auto=0, zh=3, en=4, yue=7).
public enum AudioLanguage: String, Codable, CaseIterable, Identifiable {
    case auto
    case yue
    case zh
    case en

    public var id: String { rawValue }

    public var embedIndex: Int32 {
        switch self {
        case .auto: return 0
        case .zh: return 3
        case .en: return 4
        case .yue: return 7
        }
    }

    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .yue: return "Cantonese 粵語"
        case .zh: return "Mandarin 普通話"
        case .en: return "English"
        }
    }
}

/// Language the AI summary / quiz is written in.
public enum OutputLanguage: String, Codable, CaseIterable, Identifiable {
    case zhHK = "zh-HK"
    case zhCN = "zh-CN"
    case en

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .zhHK: return "繁體中文（香港）"
        case .zhCN: return "简体中文"
        case .en: return "English"
        }
    }
}

/// SenseVoice encoder precision: fp16 (default) or int8 (~half the download,
/// accuracy-neutral) — both run on the Apple Neural Engine.
public enum EncoderPrecision: String, CaseIterable, Identifiable {
    case fp16
    case int8

    public var id: String { rawValue }

    public var label: String {
        self == .fp16 ? "FP16 (default)" : "INT8 (smaller download)"
    }
}

/// How detailed the AI summary should be (chosen in Settings).
public enum SummaryLength: String, Codable, CaseIterable, Identifiable {
    case brief
    case standard
    case inDepth = "in-depth"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .brief: return "Brief"
        case .standard: return "Standard"
        case .inDepth: return "In-depth"
        }
    }

    public var blurb: String {
        switch self {
        case .brief: return "A quick overview — a few sentences and the essentials."
        case .standard: return "The default: overview, key points, key terms, examples, follow-ups."
        case .inDepth: return "Fuller notes with more detail in every section."
        }
    }
}

/// One generated multiple-choice question (validated shape from the LLM).
public struct QuizQuestion: Codable, Hashable, Identifiable {
    public var question: String
    public var options: [String]
    public var answer: Int
    public var explanation: String

    public var id: Int { hashValue }

    public init(question: String, options: [String], answer: Int, explanation: String) {
        self.question = question
        self.options = options
        self.answer = answer
        self.explanation = explanation
    }
}

/// A generated quiz plus the Google Form created from it, if it was uploaded.
public struct Quiz: Codable, Hashable {
    public var title: String
    public var description: String
    public var questions: [QuizQuestion]
    public var formURL: String?
    public var formEditURL: String?

    public init(title: String, description: String, questions: [QuizQuestion],
                formURL: String? = nil, formEditURL: String? = nil) {
        self.title = title
        self.description = description
        self.questions = questions
        self.formURL = formURL
        self.formEditURL = formEditURL
    }
}

/// A saved lesson: the imported audio plus everything produced from it.
public struct Lesson: Codable, Identifiable, Hashable {
    public var id: String
    public var filename: String
    public var createdAt: Date
    public var audioLanguage: AudioLanguage
    public var outputLanguage: OutputLanguage
    /// Audio file name inside the lesson folder (copied in on import).
    public var audioFile: String
    public var segments: [TranscriptSegment]
    public var summaryMarkdown: String?
    public var quiz: Quiz?

    public init(id: String = UUID().uuidString.prefix(12).lowercased(),
                filename: String,
                createdAt: Date = Date(),
                audioLanguage: AudioLanguage = .auto,
                outputLanguage: OutputLanguage = .zhHK,
                audioFile: String,
                segments: [TranscriptSegment] = [],
                summaryMarkdown: String? = nil,
                quiz: Quiz? = nil) {
        self.id = String(id)
        self.filename = filename
        self.createdAt = createdAt
        self.audioLanguage = audioLanguage
        self.outputLanguage = outputLanguage
        self.audioFile = audioFile
        self.segments = segments
        self.summaryMarkdown = summaryMarkdown
        self.quiz = quiz
    }

    /// Filename without extension — the label used across the UI and exports.
    public var displayName: String {
        (filename as NSString).deletingPathExtension
    }

    public var duration: Double {
        segments.last?.end ?? 0
    }

    /// The plain-text transcript, exactly the format the web app's
    /// transcripts/*.txt files use: `[mm:ss] text` lines.
    public var transcriptText: String {
        segments.map { "[\(Self.formatTimestamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Parse the web app's transcripts/*.txt format: `[mm:ss] text` lines
    /// (optional `# filename` header lines are skipped).
    public static func parseTranscript(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close]
            let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            let seconds: Double?
            switch parts.count {
            case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: seconds = parts[0] * 60 + parts[1]
            default: seconds = nil
            }
            guard let start = seconds else { continue }
            let end = segments.last?.end ?? start
            segments.append(TranscriptSegment(start: start, end: max(end, start), text: body))
        }
        return segments
    }

    public static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60, s = total % 60
        let h = m / 60, mm = m % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, mm, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// Sanitised ASCII-ish base for exported file names, ported from the PHP
    /// docx handler (CJK names fall back to their ASCII-stripped form).
    public var exportBase: String {
        let base = displayName
        let allowed = base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == " " }
        var name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "lesson" }
        return name
    }
}

/// Extensions accepted for import — mirrors the sidecar's ALLOWED_EXTS.
public let allowedAudioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "ogg", "flac", "mp4"]
