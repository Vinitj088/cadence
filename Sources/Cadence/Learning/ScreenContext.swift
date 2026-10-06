import ApplicationServices
import Foundation

/// Reads the visible text of the window the user is dictating into, quickly and off the main
/// thread, so names on screen (email recipients, Slack names, file names) can guide this take.
enum ScreenContext {
    /// Collects up to `maxChars` of visible text within `deadline` seconds.
    static func visibleText(pid: pid_t, maxNodes: Int = 2_500, maxChars: Int = 30_000, deadline: Double = 0.12) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window: AXUIElement = app.attribute(kAXFocusedWindowAttribute) else { return "" }

        let start = Date()
        var queue: [AXUIElement] = [window]
        var visited = 0
        var pieces: [String] = []
        var total = 0
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, "AXLink", kAXCellRole, kAXButtonRole, "AXHeading", kAXMenuItemRole]

        while !queue.isEmpty, visited < maxNodes, total < maxChars, Date().timeIntervalSince(start) < deadline {
            let element = queue.removeFirst()
            visited += 1
            let role: String? = element.attribute(kAXRoleAttribute)
            if role == "AXSecureTextField" || (element.attribute(kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole { continue }
            if let role, textRoles.contains(role) {
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text: String = element.attribute(attribute), !text.isEmpty, text.count < 4_000 {
                        pieces.append(text)
                        total += text.count
                    }
                }
            }
            if let children: [AXUIElement] = element.attribute(kAXVisibleChildrenAttribute) ?? element.attribute(kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(200))
            }
        }
        return pieces.joined(separator: "\n")
    }
}
