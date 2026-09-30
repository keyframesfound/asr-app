import SwiftUI
import LessonKit

@main
struct LessonTranscriberApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var state: AppState
    @StateObject private var updater = AppUpdater()

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _state = StateObject(wrappedValue: AppState(settings: settings, store: .shared))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(state.googleAuth)
                .environmentObject(updater)
                .preferredColorScheme(.dark)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            // App menu, right under "About Lesson Transcriber".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.checkForUpdates(manual: true) }
                }
                .disabled(updater.busy)
            }
        }
    }
}
