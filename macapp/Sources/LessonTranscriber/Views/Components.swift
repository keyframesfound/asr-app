import Combine
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


// MARK: - AI loading overlay
//
// The web app's #aiOverlay, natively: a dimmed backdrop with a centered card —
// spinner, cycling step text, progress bar, Cancel. Also hosts the Google
// sign-in wait with its Try Again second chance for a closed browser tab.

struct AIOverlayView: View {
    @ObservedObject var state: AppState

    @State private var stepIndex = 0
    private let stepTimer = Timer.publish(every: 2.6, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if let overlay = state.aiOverlay {
                card(overlay)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: state.aiOverlay == nil)
        .onReceive(stepTimer) { _ in stepIndex += 1 }
        .onChange(of: state.aiOverlay?.phase) { _, _ in stepIndex = 0 }
    }

    @ViewBuilder
    private func card(_ overlay: AIOverlayState) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(title(overlay))
                .font(.headline)
            Text(currentStep(overlay))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 40, alignment: .top)
                .id(stepIndex)
                .transition(.opacity)
                .animation(.easeIn(duration: 0.2), value: stepIndex)

            if case .working = overlay.phase {
                SlidingProgressBar()
                    .frame(width: 220, height: 5)
                    .padding(.bottom, 2)
            }
            if case .authFailed(let message) = overlay.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                switch overlay.phase {
                case .auth, .authFailed:
                    Button("Try Again") { state.retryGoogleSignIn() }
                        .buttonStyle(HexPrimaryButtonStyle())
                    Button("Cancel", role: .cancel) { state.cancelAI() }
                        .buttonStyle(HexButtonStyle())
                case .working:
                    Button("Cancel", role: .cancel) { state.cancelAI() }
                        .buttonStyle(HexButtonStyle())
                }
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: 360)
        .background(Color.hexCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.hexBorder)
        )
        .padding(40)
    }

    private func title(_ overlay: AIOverlayState) -> String {
        switch overlay.kind {
        case .summary: return "AI Summary"
        case .quiz: return "Google Form Quiz"
        }
    }

    private func currentStep(_ overlay: AIOverlayState) -> String {
        switch overlay.phase {
        case .auth:
            return "Waiting for Google — approve access in your browser. "
                + "Closed the page by accident? Click Try Again."
        case .authFailed:
            return "Sign-in didn't complete."
        case .working(let work):
            let steps = steps(for: work)
            return steps[stepIndex % steps.count]
        }
    }

    private func steps(for work: AIOverlayState.Work) -> [String] {
        switch work {
        case .summary:
            return ["Reading the transcript…",
                    "Picking out the key ideas…",
                    "Structuring the summary…",
                    "Polishing the wording…",
                    "Still working — long lessons take a little longer…"]
        case .quizQuestions:
            return ["Re-reading the lesson…",
                    "Drafting the questions…",
                    "Writing the answer key…",
                    "Checking every question…",
                    "Still working — this can take up to a minute…"]
        case .quizForm:
            return ["Contacting Google…",
                    "Creating the quiz form…",
                    "Adding the questions…",
                    "Marking the correct answers…",
                    "Still working — Google is taking its time…"]
        }
    }
}

/// Indeterminate monochrome bar — a white pill sweeping the track, the native
/// counterpart of the web overlay's CSS animation.
struct SlidingProgressBar: View {
    @State private var forward = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: geo.size.width * 0.42)
                    .offset(x: forward ? geo.size.width * 0.58 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                forward.toggle()
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
    /// Segmented-control track — dark recessed well (#101010), darker than the
    /// card behind it so unselected segments visibly recede.
    static let hexSegmentTrack = Color(red: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0)
    /// Selected segment fill — lighter grey pill over the track (≈ #363636).
    static let hexSegmentSelected = Color.white.opacity(0.16)
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

// MARK: - Segmented picker
//
// Stock `.segmented` pickers give no control over segment backgrounds, and the
// native greys leave the chosen segment barely distinguishable on the dark
// theme. This replacement keeps the segmented shape in monochrome: a dark
// recessed track, sidebar-grey labels for the unselected options, and a
// lighter pill that slides under the selection.

struct HexSegmentedPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: KeyPath<Option, String>

    @Namespace private var highlight
    @State private var hovering: Option?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 && showsDivider(before: option, after: options[index - 1]) {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 14)
                }
                segment(option)
            }
        }
        .padding(2)
        .background(Color.hexSegmentTrack)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.hexBorder)
        )
    }

    /// Native-style hairline between two neighbours that are both unselected.
    private func showsDivider(before option: Option, after previous: Option) -> Bool {
        option != selection && previous != selection
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selection = option }
        } label: {
            Text(option[keyPath: label])
                .font(.callout.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.hexSidebarText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.hexSegmentSelected)
                            .matchedGeometryEffect(id: "hex-segment-highlight", in: highlight)
                    } else if hovering == option {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.05))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? option : nil }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
