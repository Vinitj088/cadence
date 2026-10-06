import AppKit
import ApplicationServices

/// What we know about where the text is about to land.
struct FocusContext {
    var appName: String?
    var bundleID: String?
    /// Up to ~300 characters immediately before the caret, if the app exposes it.
    var textBeforeCaret: String?
    /// True when a text-accepting element has focus. False is a confident "nowhere to type".
    var hasEditableFocus: Bool
    /// The focused element, for noticing corrections afterwards. Nil for password fields.
    var element: AXUIElement?
    /// A terminal: the "field" is a screen buffer, so corrections are found by matching, and
    /// the text before the cursor is program output rather than the user's writing.
    var isTerminal = false
    /// What the user recently typed into this terminal (prompt lines), for learning vocabulary.
    var recentTerminalInput: String?

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "dev.kdrag0n.MacVirt",
    ]

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = FocusContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier, textBeforeCaret: nil, hasEditableFocus: true)
        context.isTerminal = terminalBundleIDs.contains(app?.bundleIdentifier ?? "")
        guard AXIsProcessTrusted() else { return context }
        if let app { exposeAccessibility(of: app) }

        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = system.attribute(kAXFocusedUIElementAttribute) else {
            // Many Electron/web apps don't expose focus at all, so only the Finder/desktop
            // counts as a confident "nowhere to type".
            context.hasEditableFocus = context.bundleID != "com.apple.finder"
            return context
        }

        // Roles that definitely can't take typed text; anything else gets the benefit of the doubt.
        let inert: Set<String> = [kAXButtonRole, kAXImageRole, kAXListRole, kAXOutlineRole, kAXTableRole, kAXRowRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole]
        if let role: String = focused.attribute(kAXRoleAttribute), inert.contains(role) {
            context.hasEditableFocus = false
        }

        // Never read or remember anything from password fields.
        let subrole: String? = focused.attribute(kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole { return context }
        context.element = focused

        if context.isTerminal {
            let buffer: String? = focused.attribute(kAXValueAttribute)
            context.recentTerminalInput = buffer.map(Self.promptLines)
            logger.notice("focus: terminal \(context.bundleID ?? "?", privacy: .public) readable=\(buffer != nil, privacy: .public) chars=\(buffer?.count ?? 0, privacy: .public)")
            return context
        }

        if let value: String = focused.attribute(kAXValueAttribute),
           let rangeValue: AXValue = focused.attribute(kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                let ns = value as NSString
                let end = min(max(range.location, 0), ns.length)
                let start = max(0, end - 300)
                context.textBeforeCaret = ns.substring(with: NSRange(location: start, length: end - start))
            }
        }
        let role: String? = focused.attribute(kAXRoleAttribute)
        logger.notice("focus: \(context.bundleID ?? "?", privacy: .public) role=\(role ?? "?", privacy: .public) readable=\(context.textBeforeCaret != nil, privacy: .public)")
        return context
    }

    /// Chromium and Electron apps (Claude, VS Code, Slack, Chrome) only build their accessibility
    /// tree once asked. Asking is harmless for every other app, so do it once per process.
    private static var exposedPIDs: Set<pid_t> = []
    private static func exposeAccessibility(of app: NSRunningApplication) {
        guard !exposedPIDs.contains(app.processIdentifier) else { return }
        exposedPIDs.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Lines the user typed in a terminal: Claude Code reprints submitted prompts as "> …",
    /// and shell prompts end in "$ " or "% ". Program output is skipped.
    static func promptLines(_ buffer: String) -> String {
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: true).suffix(400)
        var picked: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("> ") || trimmed.hasPrefix("❯ ") {
                picked.append(String(trimmed.dropFirst(2)))
            } else if let r = trimmed.range(of: "$ ") ?? trimmed.range(of: "% "), trimmed.distance(from: trimmed.startIndex, to: r.lowerBound) < 60 {
                picked.append(String(trimmed[r.upperBound...]))
            }
        }
        return picked.suffix(40).joined(separator: "\n")
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
