import Foundation

/// Builds Word (.docx) downloads for the transcript and the AI summary.
///
/// Port of src/Docx.php: the same hand-built minimal OOXML package, the same
/// styles and heading/bullet/bold/code mapping, so the .docx files look
/// identical to the ones the web app produced.
public enum DocxWriter {
    /// - Parameters:
    ///   - kind: "transcript" or "summary"
    ///   - text: transcript text, or the summary as Markdown
    ///   - title: display title (session filename); empty → "Session"
    public static func build(kind: String, text: String, title: String) throws -> Data {
        let body = kind == "transcript"
            ? transcriptBody(text, title)
            : summaryBody(text, title)

        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes().utf8)),
            ("_rels/.rels", Data(rootRels().utf8)),
            ("word/document.xml", Data(document(body).utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels().utf8)),
            ("word/styles.xml", Data(styles().utf8)),
            ("word/numbering.xml", Data(numbering().utf8)),
        ]
        return try ZipWriter.archive(parts: parts)
    }

    // MARK: - Content assembly

    static func transcriptBody(_ text: String, _ title: String) -> String {
        let display = title.isEmpty ? "Session" : title
        var out = [heading("Title", "Transcript — \(display)")]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Bold [mm:ss] prefix, matching the PHP renderer.
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let ts = line[line.index(after: line.startIndex)..<close]
                let rest = line[line.index(after: close)...]
                let runs = [run("[\(ts)] ", type: "bold")] + inlineRuns(String(rest))
                out.append(paragraph("Normal", runs))
            } else {
                out.append(paragraph("Normal", inlineRuns(line)))
            }
        }
        return out.joined()
    }

    static func summaryBody(_ text: String, _ title: String) -> String {
        let display = title.isEmpty ? "Session" : title
        var out = [heading("Title", "Session Summary — \(display)")]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                out.append(heading("Heading2", plain(String(line.dropFirst(4)))))
            } else if line.hasPrefix("## ") {
                out.append(heading("Heading1", plain(String(line.dropFirst(3)))))
            } else if line.hasPrefix("# ") {
                out.append(heading("Heading1", plain(String(line.dropFirst(2)))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(paragraph("ListParagraph", inlineRuns(String(line.dropFirst(2))), numId: 1))
            } else {
                out.append(paragraph("Normal", inlineRuns(line)))
            }
        }
        return out.joined()
    }

    /// Renders **bold** and `code` spans into runs (port of Docx::inlineRuns).
    /// Hand-rolled scan — no regex dependency.
    static func inlineRuns(_ markdown: String) -> [String] {
        var runs: [String] = []
        var plain = ""
        var index = markdown.startIndex
        while index < markdown.endIndex {
            if markdown[index...].hasPrefix("**"),
               let close = markdown[markdown.index(index, offsetBy: 2)...].range(of: "**") {
                if !plain.isEmpty { runs.append(run(plain)); plain = "" }
                let start = markdown.index(index, offsetBy: 2)
                runs.append(run(String(markdown[start..<close.lowerBound]), type: "bold"))
                index = close.upperBound
            } else if markdown[index] == "`",
                      let close = markdown[markdown.index(after: index)...].firstIndex(of: "`") {
                if !plain.isEmpty { runs.append(run(plain)); plain = "" }
                runs.append(run(String(markdown[markdown.index(after: index)..<close]), type: "code"))
                index = markdown.index(after: close)
            } else {
                plain.append(markdown[index])
                index = markdown.index(after: index)
            }
        }
        if !plain.isEmpty { runs.append(run(plain)) }
        return runs
    }

    static func plain(_ markdown: String) -> String {
        var text = markdown
        while let open = text.range(of: "**"), let close = text[open.upperBound...].range(of: "**") {
            let start = open.upperBound
            let end = close.lowerBound
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: String(text[start..<end]))
        }
        return text.replacingOccurrences(of: "`", with: "")
    }

    // MARK: - XML fragments

    static func esc(_ text: String) -> String {
        // Drop control chars, then XML-escape — same as the PHP esc().
        let cleaned = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !($0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r") }))
        return cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func run(_ text: String, type: String = "plain") -> String {
        let rpr: String
        switch type {
        case "bold": rpr = "<w:rPr><w:b/></w:rPr>"
        case "code": rpr = "<w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/></w:rPr>"
        default: rpr = ""
        }
        return "<w:r>\(rpr)<w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r>"
    }

    static func paragraph(_ style: String, _ runs: [String], numId: Int? = nil) -> String {
        let num = numId.map { "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\($0)\"/></w:numPr>" } ?? ""
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/>\(num)</w:pPr>\(runs.joined())</w:p>"
    }

    static func heading(_ style: String, _ text: String) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(run(text))</w:p>"
    }

    // MARK: - OOXML package parts (identical to the PHP strings)

    static func document(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body>\(body)"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" "
            + "w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
            + "</w:body></w:document>"
    }

    static func contentTypes() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
            + "</Types>"
    }

    static func rootRels() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "</Relationships>"
    }

    static func documentRels() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
            + "</Relationships>"
    }

    static func styles() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr>"
            + "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/>"
            + "</w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:spacing w:after=\"240\"/></w:pPr>"
            + "<w:rPr><w:b/><w:sz w:val=\"56\"/><w:szCs w:val=\"56\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"0\"/></w:pPr>"
            + "<w:rPr><w:b/><w:color w:val=\"2F5496\"/><w:sz w:val=\"32\"/><w:szCs w:val=\"32\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:keepNext/><w:spacing w:before=\"180\" w:after=\"90\"/><w:outlineLvl w:val=\"1\"/></w:pPr>"
            + "<w:rPr><w:b/><w:color w:val=\"2F5496\"/><w:sz w:val=\"26\"/><w:szCs w:val=\"26\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>"
            + "</w:styles>"
    }

    static func numbering() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            + "<w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"&#xF0B7;\"/><w:lvlJc w:val=\"left\"/>"
            + "<w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr>"
            + "<w:rPr><w:rFonts w:ascii=\"Symbol\" w:hAnsi=\"Symbol\" w:hint=\"default\"/></w:rPr></w:lvl>"
            + "</w:abstractNum>"
            + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            + "</w:numbering>"
    }
}
