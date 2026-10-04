import AppKit
import SwiftUI
import LessonKit

@main
struct LessonTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var state: AppState
    @StateObject private var updater = AppUpdater()

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _state = StateObject(wrappedValue: AppState(settings: settings, store: .shared))
    }

    var body: some Scene {
        // id lets the app delegate's reopen path request this window back.
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(state.googleAuth)
                .environmentObject(updater)
                .preferredColorScheme(.dark)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            // App menu, right under "About Transcriber".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.checkForUpdates(manual: true) }
                }
                .disabled(updater.busy)
            }
        }
    }
}

/// SwiftUI alone leaves the app windowless when the user closes the last
/// window: clicking the dock icon does nothing. Recreate the main window the
/// way a normal Mac app reopens.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .reopenMainWindow, object: nil)
        }
        return true
    }
}

extension Notification.Name {
    static let reopenMainWindow = Notification.Name("LessonTranscriber.reopenMainWindow")
}
