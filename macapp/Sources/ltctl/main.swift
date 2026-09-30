import Foundation
import LessonKit

/// Dev CLI for headless verification of the LessonKit pipeline:
///   ltctl transcribe <file> [--lang auto|yue|zh|en] [--precision fp16|int8]
///   ltctl docx <kind transcript|summary> <file.md-or-txt> --title <t> -o out.docx
///   ltctl merge-test            (unit-check the chunk merging)
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? ""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ltctl: \(message)\n".utf8))
    exit(1)
}

func flag(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let semaphore = DispatchSemaphore(value: 0)

switch command {
case "transcribe":
    guard let path = args.dropFirst().first else { fail("usage: ltctl transcribe <file> [--lang yue]") }
    let url = URL(fileURLWithPath: path)
    let lang = AudioLanguage(rawValue: flag("--lang") ?? "auto") ?? .auto
    let precision = EncoderPrecision(rawValue: flag("--precision") ?? "fp16") ?? .fp16
    let engine = TranscriptionEngine()
    let started = Date()
    Task {
        do {
            let segments = try await engine.transcribe(
                url: url, language: lang, precision: precision,
                onUpdate: { update in
                    if let progress = update.progress {
                        FileHandle.standardError.write(Data(String(format: "[%5.1f%%] %@\n", progress, update.stage).utf8))
                    } else {
                        FileHandle.standardError.write(Data("[  …  ] \(update.stage)\n".utf8))
                    }
                },
                onSegments: { _ in })
            let elapsed = Date().timeIntervalSince(started)
            print("# \(url.lastPathComponent) — \(segments.count) segments in \(String(format: "%.1f", elapsed))s")
            for segment in segments {
                print("[\(Lesson.formatTimestamp(segment.start))-\(Lesson.formatTimestamp(segment.end))] \(segment.text)")
            }
            semaphore.signal()
        } catch {
            fail(String(describing: error))
        }
    }
    semaphore.wait()

case "summarize":
    // Live OpenRouter check: ltctl summarize <transcript.txt> [--lang zh-HK]
    // (key comes from the bundled config, or the environment to override)
    guard let path = args.dropFirst().first else { fail("usage: ltctl summarize <file> [--lang zh-HK]") }
    let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? BundledConfig.openRouterKey
    guard !key.isEmpty else { fail("no OpenRouter key in the environment or bundled config") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let lang = OutputLanguage(rawValue: flag("--lang") ?? "zh-HK") ?? .zhHK
    let lengthFlag = flag("--length").flatMap { SummaryLength(rawValue: $0) } ?? .standard
    let client = OpenRouterClient(apiKey: key, model: BundledConfig.openRouterModel)
    Task {
        do {
            let summary = try await client.summarize(transcript: text, lang: lang, length: lengthFlag)
            print(summary)
            semaphore.signal()
        } catch {
            fail(String(describing: error))
        }
    }
    semaphore.wait()

case "docx":
    guard args.count >= 3 else { fail("usage: ltctl docx <kind> <input> [--title t] -o out.docx") }
    let kind = args[1]
    guard kind == "transcript" || kind == "summary" else { fail("kind must be transcript or summary") }
    let input = args[2]
    guard let out = flag("-o") else { fail("-o out.docx required") }
    let text = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
    let title = flag("--title") ?? "Lesson"
    let data = try DocxWriter.build(kind: kind, text: text, title: title)
    try data.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(data.count) bytes)")

case "import":
    // Import a lesson into the app's store from an audio file + transcript txt
    // (the same format the PHP web app writes under transcripts/):
    //   ltctl import --audio lesson.mp3 --txt transcripts/abc123.txt [--name "Lesson 1"]
    guard let audioPath = flag("--audio") else { fail("--audio <file> required") }
    let audioURL = URL(fileURLWithPath: audioPath)
    guard FileManager.default.fileExists(atPath: audioURL.path) else { fail("audio file not found") }
    let segments: [TranscriptSegment]
    if let txtPath = flag("--txt") {
        guard let text = try? String(contentsOfFile: txtPath, encoding: .utf8) else {
            fail("could not read transcript file")
        }
        segments = Lesson.parseTranscript(text)
        guard !segments.isEmpty else { fail("no [mm:ss] lines found in the transcript file") }
    } else {
        segments = []
    }
    let name = flag("--name") ?? audioURL.lastPathComponent
    let store = LessonStore.shared
    let (id, audioFile) = try store.importAudio(
        at: audioURL, filename: audioURL.lastPathComponent)
    let lesson = Lesson(id: id, filename: name, audioFile: audioFile, segments: segments)
    try store.save(lesson)
    print("imported lesson \(lesson.id): \(name), \(segments.count) segments")

case "merge-test":
    let chunks = TranscriptionEngine.mergeChunks([
        (0.0, 10.0), (10.2, 20.0), (19.0, 44.0), (60.0, 80.0), (80.5, 90.0), (200.0, 210.0),
    ])
    print(chunks.map { String(format: "%.1f-%.1f", $0.0, $0.1) }.joined(separator: ", "))
    print("crc32(\"hello\") = \(String(format: "%08x", ZipWriter.crc32(Data("hello".utf8))))")

default:
    fail("unknown command '\(command)' — try transcribe / docx / merge-test")
}
