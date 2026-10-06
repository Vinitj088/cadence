import AppKit

/// The kind of place the user is dictating into; it decides how the text should look.
enum AppCategory: String, Codable, CaseIterable {
    case terminal, code, aiChat, chat, email, document

    var label: String {
        switch self {
        case .terminal: "Terminals"
        case .code: "Code editors"
        case .aiChat: "AI chats"
        case .chat: "Messaging"
        case .email: "Email"
        case .document: "Everything else"
        }
    }

    private static let byBundle: [String: AppCategory] = {
        var map: [String: AppCategory] = [:]
        for id in FocusContext.terminalBundleIDs { map[id] = .terminal }
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
                   "com.sublimetext.4", "com.exafunction.windsurf", "com.google.android.studio", "com.panic.Nova"] { map[id] = .code }
        for id in ["com.anthropic.claudefordesktop", "com.openai.chat", "ai.perplexity.mac"] { map[id] = .aiChat }
        for id in ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
                   "com.hnc.Discord", "ru.keepcoder.Telegram", "com.microsoft.teams2", "com.facebook.archon"] { map[id] = .chat }
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.superhuman.electron"] { map[id] = .email }
        return map
    }()

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen",
    ]

    /// Web apps recognised by their tab title.
    private static let byTitle: [(String, AppCategory)] = [
        ("Gmail", .email), ("Outlook", .email), ("Superhuman", .email),
        ("Claude", .aiChat), ("ChatGPT", .aiChat), ("Gemini", .aiChat), ("Perplexity", .aiChat),
        ("Slack", .chat), ("WhatsApp", .chat), ("Discord", .chat), ("Telegram", .chat), ("Messenger", .chat),
        ("GitHub", .code), ("Replit", .code), ("CodeSandbox", .code),
    ]

    static func detect(bundleID: String?, windowTitle: String?) -> AppCategory {
        guard let bundleID else { return .document }
        if let category = byBundle[bundleID] { return category }
        if bundleID.hasPrefix("com.jetbrains.") { return .code }
        if browsers.contains(bundleID), let title = windowTitle {
            for (needle, category) in byTitle where title.localizedCaseInsensitiveContains(needle) { return category }
        }
        return .document
    }

    /// A key for learning per-place habits: the web app for browser tabs, else the app.
    static func styleKey(bundleID: String?, windowTitle: String?) -> String {
        let id = bundleID ?? "unknown"
        if browsers.contains(id), let title = windowTitle {
            for (needle, _) in byTitle where title.localizedCaseInsensitiveContains(needle) { return "web:" + needle.lowercased() }
        }
        return id
    }
}
