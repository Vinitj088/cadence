import Foundation

/// Claude Code slash commands, built in and the user's own: "slash compact" → "/compact",
/// "slash codex rescue" → "/codex:rescue".
enum SlashCommands {
    private static let builtIn = [
        "add-dir", "agents", "bug", "clear", "compact", "config", "context", "cost", "doctor", "exit", "export", "help", "hooks",
        "ide", "init", "login", "logout", "mcp", "memory", "model", "permissions", "plugin", "pr-comments", "release-notes",
        "resume", "review", "rewind", "security-review", "status", "statusline", "terminal-setup", "todos", "usage", "vim", "voice",
    ]

    private static var cache: (commands: [String], date: Date)?

    /// Built-in commands plus custom commands and skills from ~/.claude (and plugins), cached for a minute.
    static func all() -> [String] {
        if let cache, Date().timeIntervalSince(cache.date) < 60 { return cache.commands }
        let fm = FileManager.default
        let claude = fm.homeDirectoryForCurrentUser.appending(path: ".claude")
        var names = Set(builtIn)
        // ~/.claude/commands/*.md and ~/.claude/commands/<group>/*.md → "name" / "group:name"
        if let enumerator = fm.enumerator(at: claude.appending(path: "commands"), includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "md" {
                let relative = url.path.replacingOccurrences(of: claude.appending(path: "commands").path + "/", with: "")
                names.insert(relative.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: ":"))
            }
        }
        // ~/.claude/skills/<name>/
        if let skills = try? fm.contentsOfDirectory(atPath: claude.appending(path: "skills").path) {
            names.formUnion(skills.filter { !$0.hasPrefix(".") })
        }
        // Plugin commands and skills: …/plugins/**/(commands|skills)/<name> → "plugin:name"
        if let enumerator = fm.enumerator(at: claude.appending(path: "plugins"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let parent = url.deletingLastPathComponent().lastPathComponent
                guard parent == "commands" || parent == "skills", enumerator.level <= 8 else { continue }
                // Plugin caches nest versions (…/codex/1.0.6/commands): skip version folders.
                var pluginURL = url.deletingLastPathComponent().deletingLastPathComponent()
                while pluginURL.lastPathComponent.allSatisfy({ $0.isNumber || $0 == "." }) { pluginURL.deleteLastPathComponent() }
                let plugin = pluginURL.lastPathComponent
                let name = url.deletingPathExtension().lastPathComponent
                if !name.hasPrefix("."), !plugin.isEmpty { names.insert("\(plugin):\(name)") }
            }
        }
        let commands = Array(names)
        cache = (commands, .now)
        return commands
    }

    /// Rewrites a leading spoken "slash …" into the closest known command.
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased().trimmingCharacters(in: .punctuationCharacters),
              first == "slash" || first == "/" || first.hasPrefix("/"), words.count >= 1
        else { return text }
        let spokenStart = first.hasPrefix("/") && first.count > 1 ? 0 : 1
        let commands = all()
        var best: (command: String, used: Int, score: Double)?
        for used in 1...3 where spokenStart + used <= words.count {
            var spoken = words[spokenStart..<spokenStart + used].joined().lowercased().filter { $0.isLetter || $0.isNumber }
            if spoken.hasPrefix("/") { spoken.removeFirst() }
            guard spoken.count >= 2 else { continue }
            for command in commands {
                let key = command.lowercased().filter { $0.isLetter || $0.isNumber }
                // Exact spelling beats a sound-alike; built-ins beat plugin commands of the same name.
                let score = max(WordDiff.similarity(spoken, key), WordDiff.similarity(WordDiff.phoneticKey(spoken), WordDiff.phoneticKey(key)))
                    + (spoken == key ? 0.1 : 0) + (builtIn.contains(command) ? 0.02 : 0)
                if score >= 0.78, best == nil || score > best!.score + 0.01 || (abs(score - best!.score) < 0.01 && used > best!.used) {
                    best = (command, used, score)
                }
            }
        }
        guard let best else { return text }
        let rest = words.dropFirst(spokenStart + best.used).joined(separator: " ")
        return "/" + best.command + (rest.isEmpty ? "" : " " + rest)
    }
}
