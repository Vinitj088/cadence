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

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = FocusContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier, textBeforeCaret: nil, hasEditableFocus: true)
        guard AXIsProcessTrusted() else { return context }

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
        return context
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
