import AppKit
import Carbon.HIToolbox

/// Types a transcript into the focused app while the user is still speaking, then reconciles
/// it with the final transcript, backspacing and retyping only what differs.
///
/// Only words two consecutive passes agree on are typed, and the newest word is always held
/// back, so the text rarely needs rewriting mid-sentence.
@MainActor
final class StreamTyper {
    private(set) var typed = ""
    private let pid: pid_t
    private let leading: String
    private var previous: [String] = []
    private(set) var stopped = false

    /// `leading` is prepended to the first word (a space when continuing existing text).
    init(pid: pid_t, leading: String) {
        self.pid = pid
        self.leading = leading
    }

    /// Typing only continues while the same app is in front.
    private var targetIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    func update(hypothesis: String) {
        guard !stopped else { return }
        guard targetIsFrontmost else { stopped = true; return }
        let words = hypothesis.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map(String.init)
        defer { previous = words }
        // Words both passes agree on, minus the newest (it's still likely to change).
        var stable = 0
        while stable < min(words.count, previous.count), words[stable] == previous[stable] { stable += 1 }
        stable = min(stable, words.count - 1)
        guard stable > 0 else { return }
        let target = leading + words.prefix(stable).joined(separator: " ")
        // Never retract text already typed just because a pass got shorter.
        guard target.count > typed.count || !target.hasPrefix(typed) else { return }
        replace(with: target, allowPaste: false)
    }

    /// Makes the field contain `final` where the streamed text was.
    func finish(_ final: String) {
        guard targetIsFrontmost else { return }
        replace(with: final, allowPaste: true)
        stopped = true
    }

    /// Erases everything streamed so far.
    func cancel() {
        guard targetIsFrontmost else { return }
        Self.backspace(typed.count)
        typed = ""
        stopped = true
    }

    private func replace(with target: String, allowPaste: Bool) {
        let common = typed.commonPrefix(with: target)
        let erase = typed.count - common.count
        let insert = String(target.dropFirst(common.count))
        if erase > 0 { Self.backspace(erase) }
        if !insert.isEmpty {
            // A typed newline would submit (Claude Code) or run a command; paste multi-line text instead.
            if insert.contains("\n") {
                if allowPaste { TextInserter.paste(insert, restoreClipboard: true) } else { Self.type(insert.replacingOccurrences(of: "\n", with: " ")) }
            } else {
                Self.type(insert)
            }
        }
        typed = target
    }

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            index += chunk.count
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                // The user may be holding ⌥; without clearing it, apps would read Option shortcuts.
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    static func backspace(_ count: Int) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<max(0, count) {
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: keyDown)
                event?.flags = []
                event?.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}
