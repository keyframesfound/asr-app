import SwiftUI
import LessonKit

/// Transcription progress — stage text, percent, elapsed clock, animated bar.
/// The web app's #progressWrap, natively.
struct ProgressCard: View {
    @ObservedObject var job: JobState

    var body: some View {
        Card {
            HStack {
                Text(job.stage)
                Spacer()
                Text(job.elapsedText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(job.indeterminate ? "…" : "\(Int(job.progress.rounded()))%")
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
            }
            ProgressView(value: job.indeterminate ? nil : job.progress, total: 100)
        }
    }
}

/// Tiny Markdown renderer for the AI summary — headings, bullets, **bold**,
/// `code`, the same subset the web app's renderMarkdown() handles.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    private var lines: [(indent: Bool, content: String)] {
        markdown.components(separatedBy: "\n").map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return (true, String(trimmed.dropFirst(2)))
            }
            return (false, trimmed)
        }
        .filter { !$0.content.isEmpty }
    }

    @ViewBuilder
    private func lineView(_ line: (indent: Bool, content: String)) -> some View {
        let content = line.content
        if content.hasPrefix("### ") {
            HStack(alignment: .firstTextBaseline, spacing: 0) { inline(String(content.dropFirst(4))) }
                .font(.headline)
                .padding(.top, 4)
        } else if content.hasPrefix("## ") {
            HStack(alignment: .firstTextBaseline, spacing: 0) { inline(String(content.dropFirst(3))) }
                .font(.title3.bold())
                .padding(.top, 6)
        } else if content.hasPrefix("# ") {
            HStack(alignment: .firstTextBaseline, spacing: 0) { inline(String(content.dropFirst(2))) }
                .font(.title3.bold())
                .padding(.top, 6)
        } else if line.indent {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(content)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) { inline(content) }
        }
    }

    /// Inline span: **bold** and `code` via the built-in Markdown parser.
    private func inline(_ text: String) -> some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed).textSelection(.enabled)
            } else {
                Text(text).textSelection(.enabled)
            }
        }
    }
}


// MARK: - Hex-style palette
//
// Forced monochrome theme copied from Hex's design: flat black backdrop,
// grey cards with hairline borders, greys everywhere. Buttons share the
// card grey and are picked out by a lighter grey hairline — no accent color.

extension Color {
    /// Window backdrop (black, #101010).
    static let hexBackground = Color(red: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0)
    /// Card / panel surface (grey, #171717).
    static let hexCard = Color(red: 0x17/255.0, green: 0x17/255.0, blue: 0x17/255.0)
    /// Hairline card border.
    static let hexBorder = Color.white.opacity(0.09)
    /// Row hover / selected chip.
    static let hexSelected = Color.white.opacity(0.10)
    /// Sidebar surface (lighter grey, #1F1F1F).
    static let hexSidebar = Color(red: 0x1F/255.0, green: 0x1F/255.0, blue: 0x1F/255.0)
    /// Idle sidebar text — lighter grey than .secondary so rows stay readable
    /// on #1F1F1F (#A6A6A6). Chosen rows turn white instead.
    static let hexSidebarText = Color(red: 0xA6/255.0, green: 0xA6/255.0, blue: 0xA6/255.0)
    /// Button fill — the same grey as the cards (#171717).
    static let hexButton = Color(red: 0x17/255.0, green: 0x17/255.0, blue: 0x17/255.0)
    /// Button hairline border (lighter grey, #393939).
    static let hexButtonBorder = Color(red: 0x39/255.0, green: 0x39/255.0, blue: 0x39/255.0)
}

// MARK: - Building blocks
//
// Grouped rounded cards with per-row title + subtitle and small-caps section
// labels, in the manner of modern Mac settings panes.

/// Small-caps grey section label above a card ("AI SUMMARY", "TRANSCRIPT"…).
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.8)
    }
}

/// Card container: rounded, hairline border, padded content (spacing 12).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hexCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.hexBorder)
            )
    }
}

/// Card holding full-width rows separated by hairline dividers (no padding —
/// `SettingRow` carries its own).
struct RowCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.hexCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.hexBorder)
            )
    }
}

/// One row: title (+ grey subtitle) on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control
    var showsDivider: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if showsDivider {
                Divider()
            }
        }
    }
}

/// Card header row: title (+ optional grey subtitle) with trailing actions.
struct SectionHead<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Hex-style buttons
//
// One monochrome look for every action — primaries dropped their blue fill:
// flat grey pill with a lighter grey hairline, white label, hover/press
// feedback that lightens the fill.

/// Shared chrome behind both button styles.
private struct HexButtonChrome<Label: View>: View {
    let label: Label
    let weight: Font.Weight
    var tint: Color? = nil
    var isPressed: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .font(.callout.weight(weight))
            .foregroundStyle(tint ?? Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Color.hexButton
                    .overlay(Color.white.opacity(isPressed ? 0.12 : (hovering ? 0.06 : 0))))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.hexButtonBorder))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

struct HexButtonStyle: ButtonStyle {
    var role: ButtonRole? = nil

    func makeBody(configuration: Configuration) -> some View {
        HexButtonChrome(
            label: configuration.label,
            weight: .medium,
            tint: role == .destructive ? .red : nil,
            isPressed: configuration.isPressed)
    }
}

/// Primary actions — same monochrome chrome, semibold label.
struct HexPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HexButtonChrome(
            label: configuration.label,
            weight: .semibold,
            isPressed: configuration.isPressed)
    }
}
