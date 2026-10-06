import AppKit
import Carbon.HIToolbox

/// Removes the most recent dictation from wherever it was typed.
@MainActor
final class DictationUndo {
    struct Insertion {
        let text: String
        let element: AXUIElement?
        let isTerminal: Bool
        let pid: pid_t?
        let date = Date()
    }

    private(set) var last: Insertion?

    func remember(_ insertion: Insertion) { last = insertion }

    /// Returns false when there's nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let last else { return false }
        self.last = nil
        // Make sure the keystrokes land in the app that received the text.
        if let pid = last.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        let text = last.text

        if last.isTerminal {
            // Terminal input boxes have no selection API; erase exactly what was typed.
            Self.press(UInt16(kVK_Delete), times: text.count)
            return true
        }
        if let element = last.element, let range = Self.locate(text, in: element) {
            var cfRange = CFRange(location: range.location, length: range.length)
            if let value = AXValueCreate(.cfRange, &cfRange),
               AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                Self.press(UInt16(kVK_Delete), times: 1)
                return true
            }
        }
        // Fall back to the app's own undo; a paste is a single undo step almost everywhere.
        Self.press(UInt16(kVK_ANSI_Z), flags: .maskCommand)
        return true
    }

    private static func locate(_ text: String, in element: AXUIElement) -> NSRange? {
        guard let value: String = element.attribute(kAXValueAttribute) else { return nil }
        let ns = value as NSString
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        var end = ns.length
        if let rangeValue: AXValue = element.attribute(kAXSelectedTextRangeAttribute) {
            var caret = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &caret) { end = min(ns.length, caret.location + caret.length) }
        }
        var found = ns.range(of: needle, options: .backwards, range: NSRange(location: 0, length: end))
        if found.location == NSNotFound { found = ns.range(of: needle, options: .backwards) }
        guard found.location != NSNotFound else { return nil }
        // Include the leading space Cadence added before the text, if it's there.
        if found.location > 0, text.hasPrefix(" "), ns.character(at: found.location - 1) == 32 {
            found = NSRange(location: found.location - 1, length: found.length + 1)
        }
        return found
    }

    static func press(_ key: UInt16, times: Int = 1, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<max(0, times) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// A global shortcut that is swallowed, so it never also reaches the frontmost app.
@MainActor
final class GlobalShortcut {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let keyCode: Int64
    private let flags: CGEventFlags
    private let action: () -> Void

    init(keyCode: Int, flags: CGEventFlags, action: @escaping () -> Void) {
        self.keyCode = Int64(keyCode)
        self.flags = flags
        self.action = action
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GlobalShortcut>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MainActor.assumeIsolated({ me.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let matches = MainActor.assumeIsolated {
                event.getIntegerValueField(.keyboardEventKeycode) == me.keyCode && event.flags.intersection(relevant) == me.flags
            }
            guard matches else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { me.action() }
            return nil
        }, userInfo: refcon)
        guard let tap else {
            logger.error("shortcut: couldn't create event tap")
            return
        }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
