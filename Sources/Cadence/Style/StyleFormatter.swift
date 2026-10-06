import Foundation
import Observation

/// How dictated text should look in a particular place.
struct StyleRules: Equatable {
    var codeAware = false
    var dropTrailingPeriod = false
    var lowercaseStart = false
    var allowNewlines = true
    var formatLists = false
}

/// Small edits the user makes to dictated text that reveal a writing habit in that place.
enum StyleEdit: String, Codable {
    case removedTrailingPeriod, addedTrailingPeriod, lowercasedStart, capitalizedStart
}

/// Per-app writing habits learned from the user's own edits, layered over category defaults.
@Observable
@MainActor
final class AppStyleStore {
    private struct Counts: Codable { var period = 0; var lowercase = 0 }
    private var counts: [String: Counts] = [:]
    private let url = URL.applicationSupportDirectory.appending(path: "Cadence/styles.json")

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Counts].self, from: data) {
            counts = decoded
        }
    }

    func record(_ edit: StyleEdit, for key: String) {
        var c = counts[key] ?? Counts()
        switch edit {
        case .removedTrailingPeriod: c.period = max(-3, c.period - 1)
        case .addedTrailingPeriod: c.period = min(3, c.period + 1)
        case .lowercasedStart: c.lowercase = min(3, c.lowercase + 1)
        case .capitalizedStart: c.lowercase = max(-3, c.lowercase - 1)
        }
        counts[key] = c
        logger.notice("style habit \(edit.rawValue, privacy: .public) for \(key, privacy: .public)")
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: url, options: .atomic) }
    }

    func rules(for focus: FocusContext) -> StyleRules {
        var rules = StyleRules()
        switch focus.category {
        case .terminal:
            rules.codeAware = true
            rules.allowNewlines = focus.isClaudeCodeInput
            rules.formatLists = focus.isClaudeCodeInput
        case .code:
            rules.codeAware = true
        case .aiChat, .email:
            rules.formatLists = true
        case .chat:
            rules.dropTrailingPeriod = true
        case .document:
            break
        }
        // Two consistent edits in this place override the default; opposite edits undo it.
        if let c = counts[focus.styleKey] {
            if c.period <= -2 { rules.dropTrailingPeriod = true }
            if c.period >= 2 { rules.dropTrailingPeriod = false }
            if c.lowercase >= 2 { rules.lowercaseStart = true }
        }
        return rules
    }

    /// Places where a habit has been learned, for the settings page.
    var learnedHabits: [(key: String, dropsPeriod: Bool, lowercase: Bool)] {
        counts.compactMap { key, c in
            let drops = c.period <= -2, lower = c.lowercase >= 2
            return drops || lower ? (key, drops, lower) : nil
        }.sorted { $0.key < $1.key }
    }

    func forget(_ key: String) {
        counts[key] = nil
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: url, options: .atomic) }
    }
}

/// Applies `StyleRules` to a finished transcript.
enum StyleFormatter {
    private static let shellCommands: Set<String> = [
        "git", "npm", "npx", "pnpm", "yarn", "bun", "cd", "ls", "cat", "rm", "mv", "cp", "mkdir", "touch", "open", "brew", "swift",
        "python", "python3", "pip", "node", "make", "docker", "kubectl", "ssh", "curl", "grep", "echo", "sudo", "claude", "code", "vim", "gh",
    ]

    static func apply(_ text: String, rules: StyleRules) -> String {
        var t = text
        if rules.codeAware { t = CodeFormatter.format(t) }
        if rules.formatLists { t = formatLists(t) }
        if !rules.allowNewlines {
            t = t.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
        }

        let words = t.split(whereSeparator: \.isWhitespace)
        let first = words.first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let isCommand = rules.codeAware && shellCommands.contains(first)

        // A shell command reads as code: lowercase, no full stop.
        if isCommand || rules.lowercaseStart, let i = t.firstIndex(where: \.isLetter), !isAcronymOrName(t) {
            t.replaceSubrange(i...i, with: t[i].lowercased())
        }
        let singleSentence = t.filter { ".!?".contains($0) }.count <= 1 && !t.contains("\n")
        let shortCode = rules.codeAware && words.count <= 10 && singleSentence
        if (isCommand || shortCode || (rules.dropTrailingPeriod && singleSentence)), t.hasSuffix("."), !t.hasSuffix("...") {
            t.removeLast()
        }
        return t
    }

    private static func isAcronymOrName(_ t: String) -> Bool {
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        return first == "I" || first.hasPrefix("I'") || first.dropFirst().contains(where: \.isUppercase)
    }

    // MARK: - Spoken lists

    private static let ordinals: [(String, Int)] = [
        ("first", 1), ("firstly", 1), ("number one", 1), ("second", 2), ("secondly", 2), ("number two", 2),
        ("third", 3), ("thirdly", 3), ("number three", 3), ("fourth", 4), ("fourthly", 4), ("number four", 4),
        ("fifth", 5), ("number five", 5), ("sixth", 6), ("number six", 6),
    ]

    /// "I need three things. First, fix the login. Second, update the docs. Third, ship it."
    /// becomes an intro line and a numbered list. Needs at least two markers, in order.
    static func formatLists(_ text: String) -> String {
        let pattern = #"(?i)(?:^|(?<=[.,;:!?]\s)|(?<=[.,;:!?]\sand\s)|(?<=[.,;:!?]\sthen\s))(firstly|first|secondly|second|thirdly|third|fourthly|fourth|fifth|sixth|number (?:one|two|three|four|five|six)|finally|lastly)\b[,:]?\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }

        var expected = 1
        var items: [String] = []
        var bounds: [Int] = []
        for match in matches {
            let marker = ns.substring(with: match.range(at: 1)).lowercased()
            let value = ordinals.first { $0.0 == marker }?.1 ?? (["finally", "lastly"].contains(marker) ? expected : 0)
            guard value == expected else { return text } // out of order: probably not a list
            expected += 1
            bounds.append(match.range.location)
        }
        let intro = ns.substring(to: bounds[0]).trimmingCharacters(in: .whitespaces)
        for (k, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = k + 1 < matches.count ? bounds[k + 1] : ns.length
            var item = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item = item.replacingOccurrences(of: #"(?i)[,;]?\s*(and|then)?\s*$"#, with: "", options: .regularExpression)
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: ".,; "))
            guard item.split(separator: " ").count >= 1 else { return text }
            items.append(TextPostProcessor.capitalizingFirstLetter(item))
        }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? list : intro + "\n" + list
    }
}
