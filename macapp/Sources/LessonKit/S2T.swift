import Foundation

/// Simplified → Traditional (Hong Kong written convention) conversion.
///
/// SenseVoice emits Simplified Chinese for the zh/yue languages, but the
/// app's output default is 香港繁體 (OutputLanguage.zhHK), so every recognised
/// chunk passes through here before it reaches the live view, storage and
/// exports. English text is untouched — nothing in it matches the tables.
///
/// The tables are OpenCC ver.1.1.9's STCharacters + STPhrases (see
/// S2TData.swift): phrases match longest-first and win over single
/// characters, which is what disambiguates multi-reading characters
/// (干活 → 幹活, 皇后 → 皇后). A static `let` table gives thread-safe
/// one-time parsing on first use.
public enum S2T {
    private static let table = S2TTable()

    public static func convert(_ input: String) -> String {
        guard input.contains(where: \.isCJKSimplifiedish) else { return input }
        let chars = Array(input)
        var out: [String] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            // Longest phrase match first, then the single-character table,
            // then the character as-is (punctuation, Latin, digits).
            var matched = false
            let maxLen = min(table.maxPhraseLen, chars.count - i)
            if maxLen >= 2 {
                for len in stride(from: maxLen, through: 2, by: -1) {
                    let key = String(chars[i..<i + len])
                    if let trad = table.phrases[key] {
                        out.append(trad)
                        i += len
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                let key = String(chars[i])
                out.append(table.chars[key] ?? key)
                i += 1
            }
        }
        return out.joined()
    }
}

/// Parsed OpenCC tables. Built once from the embedded data (static `let`).
private final class S2TTable {
    let chars: [String: String]
    let phrases: [String: String]
    let maxPhraseLen: Int

    init() {
        (chars, phrases, maxPhraseLen) = Self.parse(S2TData.stCharacters, S2TData.stPhrases)
    }

    /// Lines are `simplified<TAB>traditional candidates`; the first candidate
    /// is OpenCC's default. Phrase lengths feed the longest-match window.
    private static func parse(_ characterData: String, _ phraseData: String)
        -> (chars: [String: String], phrases: [String: String], maxPhraseLen: Int) {
        var chars: [String: String] = [:]
        chars.reserveCapacity(4_100)
        for line in characterData.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let trad = fields[1].split(separator: " ").first else { continue }
            chars[String(fields[0])] = String(trad)
        }
        var phrases: [String: String] = [:]
        var maxLen = 0
        phrases.reserveCapacity(49_200)
        for line in phraseData.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let trad = fields[1].split(separator: " ").first else { continue }
            let key = String(fields[0])
            phrases[key] = String(trad)
            maxLen = max(maxLen, key.count)
        }
        return (chars, phrases, maxLen)
    }
}

private extension Character {
    /// Cheap gate: a Character is worth a table lookup only if it could be
    /// Han (or an extension thereof). ASCII-only transcripts skip conversion
    /// entirely.
    var isCJKSimplifiedish: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
