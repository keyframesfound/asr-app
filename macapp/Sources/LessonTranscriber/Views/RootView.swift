import SwiftUI
import LessonKit

/// Root layout, in the manner of Hex: near-black window (no title bar — the
/// traffic lights float over the sidebar), sidebar with Settings + lessons,
/// and detail panes that carry their own big titles.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: AppUpdater
    @State private var renamingLesson: Lesson?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    NavigationLink(value: "settings") {
                        SidebarItem(icon: "gearshape", title: "Settings",
                                    subtitle: nil, selected: state.showSettings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    SidebarSearchField(text: $searchText)
                    NavigationLink(value: "new") {
                        SidebarItem(icon: "plus", title: "New Session",
                                    subtitle: nil,
                                    selected: !state.showSettings && state.selection == nil)
                    }
                }
                Section {
                    ForEach(filteredLessons) { lesson in
                        NavigationLink(value: lesson.id) {
                            SidebarItem(icon: "waveform", title: lesson.displayName,
                                        subtitle: lessonSubtitle(lesson),
                                        selected: !state.showSettings && state.selection == lesson.id)
                        }
                        .contextMenu {
                            Button("Rename…") { renamingLesson = lesson }
                            Button("Share…") { state.shareLesson(lesson) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                state.deleteLesson(lesson)
                            }
                        }
                    }
                    if filteredLessons.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "No Sessions Found" : "No matching sessions")
                            .font(.callout)
                            .foregroundStyle(Color.hexSidebarText)
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(Color.white.opacity(0.14)) // grey selection chip, like Hex
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 24) }
            .safeAreaInset(edge: .bottom) { versionFooter }
            .background { Color.hexSidebar.ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
                .background { Color.hexBackground.ignoresSafeArea() }
        }
        // The split view would paint a grey strip on top — hide the window
        // toolbar; Settings and New Session live in the sidebar instead.
        .toolbar(.hidden, for: .windowToolbar)
        .navigationTitle("")
        // Monochrome controls everywhere — progress bars, quiz answer dots and
        // any other accent-following control join the greys, not the system blue.
        .tint(.white)
        .sheet(item: $renamingLesson) { lesson in
            RenameSheet(lesson: lesson)
                .environmentObject(state)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.globalError ?? "")
        }
        .background { WindowMover() }
        .task { await updater.startupCheckIfNeeded() }
    }

    /// Lessons filtered by the sidebar search field (display-name match).
    private var filteredLessons: [Lesson] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return state.lessons }
        return state.lessons.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Version pinned to the very bottom of the sidebar; gains an update pill
    /// whenever the updater has found a newer release (tap → Settings).
    private var versionFooter: some View {
        HStack(spacing: 8) {
            Text("Version \(version)")
                .font(.footnote)
                .foregroundStyle(Color.hexSidebarText)
            if updater.updateAvailable {
                Button {
                    state.showSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(updater.updateVersion.map { "v\($0)" } ?? "Update")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.hexSelected, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.hexButtonBorder))
                }
                .buttonStyle(.plain)
                .help("Update available — click to install")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Marketing version from the built app's Info.plist (dev builds fall
    /// back to the build script's value).
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// The sidebar selection spans the settings pane and the lesson list.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { state.showSettings ? "settings" : state.selection },
            set: { value in
                if value == "settings" {
                    state.showSettings = true
                } else if value == "new" {
                    state.showSettings = false
                    state.selection = nil
                } else {
                    state.showSettings = false
                    state.selection = value
                }
            })
    }

    @ViewBuilder
    private var detail: some View {
        if state.showSettings {
            SettingsView()
        } else if let lesson = state.selectedLesson {
            LessonDetailView(lesson: lesson)
        } else {
            NewLessonView()
        }
    }

    private func lessonSubtitle(_ lesson: Lesson) -> String {
        let date = lesson.createdAt.formatted(date: .abbreviated, time: .shortened)
        let duration = Lesson.formatTimestamp(lesson.duration)
        return lesson.duration > 0 ? "\(date) · \(duration)" : date
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { state.globalError != nil },
                set: { if !$0 { state.globalError = nil } })
    }
}

/// Sidebar search field: dark rounded chip with a magnifier and a clear
/// button, between Settings and New Session.
struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.hexSidebarText)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.hexSidebarText) // lighter grey, uniform with the sidebar rows
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hexSidebarText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.hexCard, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.hexBorder, lineWidth: 1)
        }
        .padding(.vertical, 2)
    }
}

/// Sidebar row: icon in a grey chip + title (+ grey subtitle), Hex-style.
/// The chosen row turns white (icon + title), like Hex's sidebar; unchosen
/// rows stay grey.
struct SidebarItem: View {
    let icon: String
    let title: String
    let subtitle: String?
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.hexSidebarText)
                .frame(width: 26, height: 26)
                .background(Color.hexSelected, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.hexSidebarText)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.hexSidebarText)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Rename dialog for a lesson (audio file extension is preserved).
struct RenameSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let lesson: Lesson

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session").font(.headline)
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(HexButtonStyle())
                Button("Rename", action: save)
                    .buttonStyle(HexPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = lesson.displayName }
    }

    private func save() {
        state.rename(lesson, to: name)
        dismiss()
    }
}

/// Blends the system title bar into the content: transparent title bar,
/// full-size content view, no title text, background dragging — so the
/// near-black panes run edge to edge and the traffic lights float.
struct WindowMover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Self.configure(view.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        // The area reserved for the (hidden) toolbar shows the window
        // background — paint it the same black as the panes.
        window.backgroundColor = NSColor(red: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0, alpha: 1)
    }
}
