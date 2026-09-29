<?php

/** Builds Word (.docx) downloads for the transcript and the AI summary.
 *
 * The summary arrives as the Markdown the LLM produced; a small renderer maps
 * headings, bullets, **bold** and `code` onto Word styles. Replaces the old
 * python-docx approach with a hand-built minimal OOXML package (ext-zip only).
 */
final class Docx
{
    /** @return string the .docx bytes */
    public static function build(string $kind, string $text, string $title): string
    {
        $body = $kind === 'transcript' ? self::transcriptBody($text, $title) : self::summaryBody($text, $title);
        $display = $title !== '' ? $title : 'Lesson';

        $parts = [
            '[Content_Types].xml' => self::contentTypes(),
            '_rels/.rels' => self::rootRels(),
            'word/document.xml' => self::document($body),
            'word/_rels/document.xml.rels' => self::documentRels(),
            'word/styles.xml' => self::styles(),
            'word/numbering.xml' => self::numbering(),
        ];
        return self::zip($parts);
    }

    /* ---------- content assembly ---------- */

    /** @return string document.xml body inner XML */
    private static function transcriptBody(string $text, string $title): string
    {
        $display = $title !== '' ? $title : 'Lesson';
        $out = [self::heading('Title', "Transcript — $display")];
        foreach (preg_split('/\r\n|\r|\n/', $text) as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') {
                continue;
            }
            if (preg_match('/^\[([0-9:]+)\]\s*(.*)$/', $line, $m) === 1) {
                $out[] = self::paragraph('Normal', [self::run("[{$m[1]}] ", 'bold'), ...self::inlineRuns($m[2])]);
            } else {
                $out[] = self::paragraph('Normal', self::inlineRuns($line));
            }
        }
        return implode('', $out);
    }

    /** @return string document.xml body inner XML */
    private static function summaryBody(string $text, string $title): string
    {
        $display = $title !== '' ? $title : 'Lesson';
        $out = [self::heading('Title', "Lesson Summary — $display")];
        foreach (preg_split('/\r\n|\r|\n/', $text) as $line) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            if (str_starts_with($line, '### ')) {
                $out[] = self::heading('Heading2', self::plain(substr($line, 4)));
            } elseif (str_starts_with($line, '## ')) {
                $out[] = self::heading('Heading1', self::plain(substr($line, 3)));
            } elseif (str_starts_with($line, '# ')) {
                $out[] = self::heading('Heading1', self::plain(substr($line, 2)));
            } elseif (str_starts_with($line, '- ') || str_starts_with($line, '* ')) {
                $out[] = self::paragraph('ListParagraph', self::inlineRuns(substr($line, 2)), 1);
            } else {
                $out[] = self::paragraph('Normal', self::inlineRuns($line));
            }
        }
        return implode('', $out);
    }

    /** Renders **bold** and `code` spans into runs. @return array<int, string> */
    private static function inlineRuns(string $markdown): array
    {
        $parts = preg_split('/(\*\*[^*]+\*\*|`[^`]+`)/', $markdown, -1, PREG_SPLIT_DELIM_CAPTURE);
        $runs = [];
        foreach ($parts as $part) {
            if ($part === null || $part === '') {
                continue;
            }
            if (str_starts_with($part, '**') && str_ends_with($part, '**')) {
                $runs[] = self::run(substr($part, 2, -2), 'bold');
            } elseif (str_starts_with($part, '`') && str_ends_with($part, '`')) {
                $runs[] = self::run(substr($part, 1, -1), 'code');
            } else {
                $runs[] = self::run($part);
            }
        }
        return $runs;
    }

    private static function plain(string $markdown): string
    {
        return str_replace('`', '', preg_replace('/\*\*([^*]+)\*\*/', '$1', $markdown));
    }

    /* ---------- XML fragments ---------- */

    private static function esc(string $text): string
    {
        $text = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F]/', '', $text) ?? '';
        return htmlspecialchars($text, ENT_QUOTES | ENT_XML1, 'UTF-8');
    }

    private static function run(string $text, string $type = 'plain'): string
    {
        $rpr = '';
        if ($type === 'bold') {
            $rpr = '<w:rPr><w:b/></w:rPr>';
        } elseif ($type === 'code') {
            $rpr = '<w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr>';
        }
        return '<w:r>' . $rpr . '<w:t xml:space="preserve">' . self::esc($text) . '</w:t></w:r>';
    }

    /** @param array<int, string> $runs */
    private static function paragraph(string $style, array $runs, ?int $numId = null): string
    {
        $num = $numId !== null ? "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"$numId\"/></w:numPr>" : '';
        return '<w:p><w:pPr><w:pStyle w:val="' . $style . '"/>' . $num . '</w:pPr>' . implode('', $runs) . '</w:p>';
    }

    private static function heading(string $style, string $text): string
    {
        return '<w:p><w:pPr><w:pStyle w:val="' . $style . '"/></w:pPr>' . self::run($text) . '</w:p>';
    }

    /* ---------- OOXML package parts ---------- */

    private static function document(string $body): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            . '<w:body>' . $body
            . '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
            . '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
            . 'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
            . '</w:body></w:document>';
    }

    private static function contentTypes(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            . '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            . '<Default Extension="xml" ContentType="application/xml"/>'
            . '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            . '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
            . '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
            . '</Types>';
    }

    private static function rootRels(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            . '</Relationships>';
    }

    private static function documentRels(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            . '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
            . '</Relationships>';
    }

    private static function styles(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            . '<w:docDefaults><w:rPrDefault><w:rPr>'
            . '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/>'
            . '</w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>'
            . '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
            . '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>'
            . '<w:pPr><w:spacing w:after="240"/></w:pPr>'
            . '<w:rPr><w:b/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr></w:style>'
            . '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/>'
            . '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>'
            . '<w:rPr><w:b/><w:color w:val="2F5496"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>'
            . '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>'
            . '<w:pPr><w:keepNext/><w:spacing w:before="180" w:after="90"/><w:outlineLvl w:val="1"/></w:pPr>'
            . '<w:rPr><w:b/><w:color w:val="2F5496"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>'
            . '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>'
            . '<w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style>'
            . '</w:styles>';
    }

    private static function numbering(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            . '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>'
            . '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#xF0B7;"/><w:lvlJc w:val="left"/>'
            . '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
            . '<w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>'
            . '</w:abstractNum>'
            . '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
            . '</w:numbering>';
    }

    /** @param array<string, string> $parts @return string the zip bytes */
    private static function zip(array $parts): string
    {
        if (!class_exists(ZipArchive::class)) {
            throw new RuntimeException('The php-zip extension is required for Word export.');
        }
        $tmp = tempnam(sys_get_temp_dir(), 'docx');
        if ($tmp === false) {
            throw new RuntimeException('Could not create a temporary file for the Word export.');
        }
        $zip = new ZipArchive();
        if ($zip->open($tmp, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
            throw new RuntimeException('Could not create the Word file (temp dir not writable?).');
        }
        foreach ($parts as $name => $content) {
            $zip->addFromString($name, $content);
        }
        $zip->close();
        $bytes = file_get_contents($tmp);
        unlink($tmp);
        if ($bytes === false) {
            throw new RuntimeException('Could not read back the generated Word file.');
        }
        return $bytes;
    }
}
