import AppKit

/// Turns raw presses of the trigger key into dictation intents.
///
/// - Hold the key and speak; releasing ends the take (push-to-talk).
/// - Tap it quickly and dictation stays on hands-free until the next tap.
/// - Press any other key while holding it and the take is abandoned, so the modifier
///   still works normally in shortcuts like ⌥E.
/// - Escape cancels whatever is in progress.
@MainActor
final class HotkeyMonitor {
    enum Event {
        case begin
        case lockedHandsFree
        case finish
        case cancel
    }

    var onEvent: ((Event) -> Void)?
    var triggerKey: TriggerKey = .rightOption

    /// Releases shorter than this count as a tap rather than a hold.
    private let tapThreshold: TimeInterval = 0.28

    private enum State { case idle, holding(since: Date), handsFree }
    private var state: State = .idle
    private var isDown = false
    private var monitors: [Any] = []

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keys: (NSEvent) -> Void = { [weak self] event in self?.handleKeyDown(event) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Called by the app when a take ends some other way (e.g. clicking Stop on the overlay).
    func reset() {
        state = .idle
    }

    private func handleFlags(_ event: NSEvent) {
        guard triggerKey.keyCodes.contains(event.keyCode) else { return }
        let pressed = isPressed(event.modifierFlags)
        guard pressed != isDown else { return }
        isDown = pressed

        switch (state, pressed) {
        case (.idle, true):
            state = .holding(since: Date())
            onEvent?(.begin)
        case (.holding(let since), false):
            if Date().timeIntervalSince(since) < tapThreshold {
                state = .handsFree
                onEvent?(.lockedHandsFree)
            } else {
                state = .idle
                onEvent?(.finish)
            }
        case (.handsFree, true):
            state = .idle
            onEvent?(.finish)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape
            guard case .idle = state else {
                state = .idle
                onEvent?(.cancel)
                return
            }
            return
        }
        // Another key while the trigger is held: it's a shortcut, not dictation.
        if case .holding = state, isDown {
            state = .idle
            onEvent?(.cancel)
        }
    }

    /// Uses the device-dependent bits (NX_DEVICER*KEYMASK) so holding the left-hand twin
    /// of the trigger doesn't mask the right-hand key's release.
    private func isPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch triggerKey {
        case .rightOption: return raw & 0x40 != 0
        case .leftOption: return raw & 0x20 != 0
        case .eitherOption: return raw & 0x60 != 0
        case .rightCommand: return raw & 0x10 != 0
        case .rightControl: return raw & 0x2000 != 0
        case .rightShift: return raw & 0x04 != 0
        case .fn: return flags.contains(.function)
        }
    }
}
