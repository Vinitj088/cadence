import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    enum State { case granted, denied, undetermined }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    static func requestMicrophone(_ completion: (@MainActor (Bool) -> Void)? = nil) {
        if microphone == .denied {
            open("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in completion?(granted) }
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (first time) and opens the right Settings pane.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("Privacy_Accessibility")
        }
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
