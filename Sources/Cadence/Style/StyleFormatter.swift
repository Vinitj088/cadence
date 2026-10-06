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

    /// Turns a spoken enumeration into an intro and a numbered list:
    /// "I need three things. First, fix the login. Second, update the docs. Third, ship it." and
    /// "I need following things, first is the list, second is the check, third is the fixes."
    ///
    /// Later markers must start a clause (after punctuation, "and" or "then"), or introduce an item
    /// ("second is …"). The first may sit mid-sentence only when it introduces an item, so
    /// "at first I thought… the second time" is left alone. Needs at least two markers in order.
    static func formatLists(_ text: String) -> String {
        let pattern = #"(?i)\b(firstly|first|secondly|second|thirdly|third|fourthly|fourth|fifthly|fifth|sixth|number (?:one|two|three|four|five|six)|finally|lastly)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString

        struct Marker { var range: NSRange; var bodyStart: Int }
        var markers: [Marker] = []
        var expected = 1
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            let value = ordinals.first { $0.0 == word }?.1 ?? (["finally", "lastly"].contains(word) && expected > 2 ? expected : 0)
            guard value == expected else { continue }

            let before = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces).lowercased()
            let clauseStart = before.isEmpty || ".,;:!?".contains(before.last!) || before.hasSuffix(" and") || before.hasSuffix(" then")
            let after = ns.substring(from: NSMaxRange(match.range)).lowercased()
            let introducesItem = after.hasPrefix(",") || after.hasPrefix(":") || after.hasPrefix(" is ") || after.hasPrefix(" would be ")
            // "First of all" is a figure of speech, not a list.
            if after.hasPrefix(" of all") { continue }
            guard clauseStart || introducesItem else { continue }

            // The item starts after the marker and any "is", "would be" or punctuation.
            var bodyStart = NSMaxRange(match.range)
            let lead = ns.substring(from: bodyStart)
            if let r = lead.range(of: #"^[,:]?\s*(?:(?:is|would be)(?:\s+that)?\s+)?"#, options: [.regularExpression, .caseInsensitive]) {
                bodyStart += lead[r].utf16.count
            }
            markers.append(Marker(range: match.range, bodyStart: bodyStart))
            expected += 1
        }
        guard markers.count >= 2 else { return text }

        var intro = ns.substring(to: markers[0].range.location).trimmingCharacters(in: .whitespaces)
        intro = intro.replacingOccurrences(of: #"(?i)[,;]?\s*(?:and|then)?\s*$"#, with: "", options: .regularExpression)
        if let last = intro.last, !".:!?".contains(last) { intro += ":" }

        var items: [String] = []
        for (k, marker) in markers.enumerated() {
            let end = k + 1 < markers.count ? markers[k + 1].range.location : ns.length
            guard end > marker.bodyStart else { return text }
            var item = ns.substring(with: NSRange(location: marker.bodyStart, length: end - marker.bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item = item.replacingOccurrences(of: #"(?i)[,;]?\s*(?:and|then)?\s*$"#, with: "", options: .regularExpression)
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: ".,; "))
            guard !item.isEmpty else { return text }
            items.append(TextPostProcessor.capitalizingFirstLetter(item))
        }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? list : intro + "\n" + list
    }
}
