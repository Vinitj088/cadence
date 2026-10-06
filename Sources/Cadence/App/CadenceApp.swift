import ServiceManagement
import SwiftUI

/// The app's long-lived objects, shared by every scene.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let prefs = Preferences.shared
    let models = ModelManager()
    let history = HistoryStore()
    let learning = LearningStore()
    let styles = AppStyleStore()
    lazy var dictation = DictationController(prefs: prefs, models: models, history: history, learning: learning, styles: styles)
}

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        Window("Cadence", id: "main") {
            RootView()
                .environment(env.prefs)
                .environment(env.models)
                .environment(env.history)
                .environment(env.learning)
                .environment(env.styles)
                .environment(env.dictation)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(env.prefs)
                .environment(env.models)
                .environment(env.history)
                .environment(env.learning)
                .environment(env.styles)
                .environment(env.dictation)
        } label: {
            MenuBarIcon(dictation: env.dictation)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the app's lifetime. Without it macOS App Naps a background agent app, which
    /// throttles timers and animations — the overlay could be ordered on screen but stay invisible.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Responds instantly to the dictation key"
        )
        let env = AppEnvironment.shared
        env.dictation.start()

        // Cadence stays a menu-bar (agent) app even while its window is open: only agent apps'
        // panels may appear over another app's full-screen space, which the overlay needs.

        if env.prefs.hasOnboarded && Permissions.accessibility && Permissions.microphone == .granted {
            DispatchQueue.main.async {
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.close()
            }
        } else {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc func showOnboarding() {
        AppEnvironment.shared.prefs.hasOnboarded = false
        showMainWindow()
    }

    @objc func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            OpenWindowBridge.open?("main")
        }
    }
}

/// Lets AppKit code open SwiftUI windows.
@MainActor
enum OpenWindowBridge {
    static var open: ((String) -> Void)?
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Cadence: launch at login change failed: \(error.localizedDescription)")
        }
    }
}
