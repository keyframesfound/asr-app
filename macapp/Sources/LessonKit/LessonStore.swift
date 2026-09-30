import Foundation

/// Persistence for saved lessons — the Mac replacement for the web app's
/// uploads/, transcripts/ and jobs/ folders. Each lesson gets a folder under
/// Application Support holding its audio file and a lesson.json.
public final class LessonStore: @unchecked Sendable {
    public static let shared = LessonStore()

    public let root: URL

    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("LessonTranscriber", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: lessonsDirectory, withIntermediateDirectories: true)
    }

    public var lessonsDirectory: URL {
        root.appendingPathComponent("Lessons", isDirectory: true)
    }

    public func folder(for lesson: Lesson) -> URL {
        lessonsDirectory.appendingPathComponent(lesson.id, isDirectory: true)
    }

    public func audioURL(for lesson: Lesson) -> URL {
        folder(for: lesson).appendingPathComponent(lesson.audioFile)
    }

    /// Import: copy the picked file into a fresh lesson folder.
    public func importAudio(at source: URL, filename: String) throws -> (lessonID: String, audioFile: String) {
        let id = UUID().uuidString.prefix(12).lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        let dir = lessonsDirectory.appendingPathComponent(String(id), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("audio.\(ext)")
        // .resetUbiquitous? no — plain copy; drop the quarantine bit implicitly by rewriting.
        try FileManager.default.copyItem(at: source, to: dest)
        return (String(id), dest.lastPathComponent)
    }

    public func save(_ lesson: Lesson) throws {
        let dir = folder(for: lesson)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(lesson)
        try data.write(to: dir.appendingPathComponent("lesson.json"), options: .atomic)
    }

    public func delete(_ lesson: Lesson) {
        try? FileManager.default.removeItem(at: folder(for: lesson))
    }

    public func loadAll() -> [Lesson] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: lessonsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var lessons: [Lesson] = []
        for dir in entries where dir.hasDirectoryPath {
            let meta = dir.appendingPathComponent("lesson.json")
            guard let data = try? Data(contentsOf: meta),
                  let lesson = try? decoder.decode(Lesson.self, from: data) else { continue }
            lessons.append(lesson)
        }
        return lessons.sorted { $0.createdAt > $1.createdAt }
    }
}
