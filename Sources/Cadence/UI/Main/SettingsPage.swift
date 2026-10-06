import SwiftUI

struct SettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(DictationController.self) private var dictation
    @ViewState private var microphones: [AudioInputDevice] = []
    @ViewState private var launchAtLogin = LaunchAtLogin.isEnabled
    @ViewState private var accessibilityGranted = Permissions.accessibility
    @ViewState private var micState = Permissions.microphone

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Settings", subtitle: "Make Cadence fit the way you work.")

            Card(title: "Shortcut") {
                SettingRow(title: "Dictation key", detail: "Hold to talk, tap for hands-free. Right-hand modifiers don't clash with shortcuts.") {
                    Picker("", selection: $prefs.triggerKey) {
                        ForEach(TriggerKey.allCases) { key in Text(key.label).tag(key) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: prefs.triggerKey) { dictation.applyTriggerKey() }
                }
                if prefs.triggerKey == .fn {
                    Label("Set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard so macOS doesn't also react.", systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "Microphone") {
                SettingRow(title: "Input", detail: nil) {
                    Picker("", selection: $prefs.microphoneUID) {
                        Text("Automatic").tag(String?.none)
                        Divider()
                        ForEach(microphones) { mic in Text(mic.name).tag(String?.some(mic.uid)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                Divider().opacity(0.5)
                SettingRow(title: "Prefer built-in mic over Bluetooth", detail: "Recording from AirPods drops them into low-quality call mode, which hurts accuracy and your music.") {
                    Toggle("", isOn: $prefs.preferBuiltInMic).labelsHidden().toggleStyle(.switch)
                }
            }

            Card(title: "Writing") {
                SettingRow(title: "Remove filler words", detail: "Drops “um”, “uh” and stutters like “the the”.") {
                    Toggle("", isOn: $prefs.removeFillers).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                SettingRow(title: "Smart formatting", detail: "Numbers as digits, and “new line” / “new paragraph” commands.") {
                    Toggle("", isOn: $prefs.smartFormatting).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                SettingRow(title: "Match surrounding text", detail: "Reads the text before your cursor to get spacing and capitalization right, and gives Whisper it as context.") {
                    Toggle("", isOn: $prefs.contextAware).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                SettingRow(
                    title: "AI polish",
                    detail: Polisher.unavailableReason ?? "Apple's on-device model fixes grammar, false starts and self-corrections. Adds about half a second."
                ) {
                    Toggle("", isOn: $prefs.aiPolish)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!Polisher.isAvailable)
                        .onChange(of: prefs.aiPolish) { if prefs.aiPolish { Polisher.prewarm() } }
                }
            }

            Card(title: "Feel") {
                SettingRow(title: "Resting pill", detail: "Keep a thin dash on screen that expands into the pill when you dictate. Click it to start hands-free.") {
                    Toggle("", isOn: $prefs.showIdlePill)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: prefs.showIdlePill) { dictation.applyOverlaySettings() }
                }
                Divider().opacity(0.5)
                SettingRow(title: "Overlay position", detail: "Or just drag the pill. It snaps to the nearest spot.") {
                    Picker("", selection: $prefs.overlayAnchor) {
                        ForEach(OverlayAnchor.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().opacity(0.5)
                SettingRow(title: "Sounds", detail: "A soft chime when recording starts and stops.") {
                    Toggle("", isOn: $prefs.playSounds).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                SettingRow(title: "Restore clipboard after pasting", detail: "Cadence pastes through the clipboard, then puts back what you had copied.") {
                    Toggle("", isOn: $prefs.restoreClipboard).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                SettingRow(title: "Open at login", detail: nil) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { LaunchAtLogin.set(launchAtLogin) }
                }
            }

            Card(title: "Privacy") {
                SettingRow(title: "Keep recordings for 14 days", detail: "Lets you re-transcribe a take with a different model. Stored only on this Mac.") {
                    Toggle("", isOn: $prefs.keepAudio).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                permissionRow("Microphone", granted: micState == .granted) {
                    Permissions.requestMicrophone { _ in micState = Permissions.microphone }
                }
                Divider().opacity(0.5)
                permissionRow("Accessibility", granted: accessibilityGranted) {
                    Permissions.requestAccessibility()
                }
            }

            HStack {
                Spacer()
                Button("Run setup again") {
                    prefs.hasOnboarded = false
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func permissionRow(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingRow(title: name, detail: nil) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: action).controlSize(.small)
            }
        }
    }

    private func refresh() {
        microphones = AudioDevices.inputs()
        accessibilityGranted = Permissions.accessibility
        micState = Permissions.microphone
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
