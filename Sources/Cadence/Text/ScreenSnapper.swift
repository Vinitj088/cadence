import Foundation

/// Snaps spoken renderings of things visible on screen to their exact written form:
/// "application super whisper app contents resources" → "/Applications/superwhisper.app/Contents/Resources",
/// "screen codex" → "ScreenContext" when ScreenContext is on screen.
/// Only things on screen for this take are candidates, which is what keeps this safe.
enum ScreenSnapper {
    /// File paths in screen text: at least two separators, e.g. /Applications/x.app/Contents or ~/Documents/a/b.ts.
    static func paths(in text: String) -> [String] {
        let pattern = #"(?:~|\.{0,2})?/(?:[A-Za-z0-9_.\-]+/)+[A-Za-z0-9_.\-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var path = ns.substring(with: match.range)
            while let last = path.last, ".,:;)".contains(last) { path.removeLast() }
            guard path.filter({ $0 == "/" }).count >= 2, path.count >= 8, seen.insert(path).inserted else { continue }
            result.append(path)
            if result.count >= 25 { break }
        }
        return result
    }

    /// Words a speaker inserts while reading a path or identifier aloud.
    private static let spokenSeparators: Set<String> = ["slash", "forward", "backslash", "dot", "dash", "underscore", "the", "in", "inside", "into", "folder", "directory", "file"]

    private struct Target {
        let written: String
        let parts: [String]
        let isPath: Bool
        /// From a large pool (a whole project): only a near-exact spelling match counts, never a
        /// sound-alike, or ordinary speech gets snapped onto code ("number one" → NumberInput).
        var strict = false
        var key: String { parts.joined() }
    }

    /// Web domains and email addresses on screen, e.g. "mugammaconsultants.com".
    static func domains(in text: String) -> [String] {
        let pattern = #"\b[A-Za-z0-9._%+-]*@?[A-Za-z0-9-]{3,}(?:\.[A-Za-z0-9-]+)*\.(?:com|in|io|ai|org|net|dev|app|co|co\.in|us|uk)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let domain = ns.substring(with: match.range)
            return domain.count >= 8 && seen.insert(domain.lowercased()).inserted ? domain : nil
        }
    }

    /// - paths: file paths on screen; identifiers: names on screen, in the project and vocabulary;
    /// - files: project files (repo-relative) for "at <file>" mentions, when `mentions` is on.
    static func snap(_ text: String, paths: [String], identifiers: [String], projectSymbols: [String] = [], domains: [String] = [],
                     files: [String] = [], mentions: Bool = false) -> String {
        var targets: [Target] = paths.map { Target(written: $0, parts: pathParts($0), isPath: true) }
        var seen = Set<String>()
        for identifier in identifiers where isCompoundIdentifier(identifier) {
            let written = base(identifier)
            if seen.insert(written).inserted { targets.append(Target(written: written, parts: identifierParts(identifier), isPath: false)) }
        }
        for symbol in projectSymbols where isCompoundIdentifier(symbol) {
            let written = base(symbol)
            if seen.insert(written).inserted { targets.append(Target(written: written, parts: identifierParts(symbol), isPath: false, strict: true)) }
        }
        // "mu gamma consultants dot com" → "mugammaconsultants.com"
        for domain in domains where seen.insert(domain).inserted {
            let parts = domain.split(whereSeparator: { ".@-_".contains($0) }).map { squash(String($0)) }.filter { !$0.isEmpty }
            if parts.count >= 2 { targets.append(Target(written: domain, parts: parts, isPath: false, strict: true)) }
        }
        // File names, extension included: "screen context swift" → "ScreenContext.swift".
        for file in files {
            let name = (file as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            guard isCompoundIdentifier(stem), !ext.isEmpty, seen.insert(name).inserted else { continue }
            targets.append(Target(written: name, parts: identifierParts(stem) + [squash(ext)], isPath: false, strict: true))
        }
        // Bucket by the first two letters so each spoken word is only tried against plausible targets.
        var buckets: [String: [Target]] = [:]
        for target in targets where target.key.count >= (target.isPath ? 10 : 8) {
            buckets[String(target.parts[0].prefix(2)), default: []].append(target)
        }
        var fileTargets: [String: [Target]] = [:]
        if mentions {
            for file in files {
                let name = (file as NSString).lastPathComponent
                let parts = camelWords(Substring((name as NSString).deletingPathExtension))
                    .flatMap { $0.split(whereSeparator: { "-_.".contains($0) }).map(String.init) }
                    .map(squash).filter { !$0.isEmpty }
                guard !parts.isEmpty, parts.joined().count >= 4 else { continue }
                fileTargets[String(parts[0].prefix(2)), default: []].append(Target(written: "@" + file, parts: parts, isPath: false, strict: true))
            }
        }

        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < words.count {
            let word = squash(words[i])
            // "at dictation controller" → "@Sources/…/DictationController.swift"
            let previous = i > 0 ? squash(words[i - 1]) : ""
            let mentionVerbs: Set<String> = ["open", "read", "check", "edit", "update", "see", "review", "in", "inside", "into", "from", "look", "fix", "change", "refactor"]
            if mentions, word == "at" || (word == "a" && mentionVerbs.contains(previous)), i + 1 < words.count,
               let candidates = fileTargets[String(squash(words[i + 1]).prefix(2))],
               let match = bestMatch(words, from: i + 1, among: candidates, minimum: 4) {
                let trailing = String(words[match.end].reversed().prefix { ".,;:!?".contains($0) }.reversed())
                words.replaceSubrange(i...match.end, with: [match.target.written + trailing])
                i += 1
                continue
            }
            if word.count >= 2, let candidates = buckets[String(word.prefix(2))],
               let match = bestMatch(words, from: i, among: candidates, minimum: 8) {
                let written = match.target.isPath ? prefixPath(match.target.written, components: match.partCount) : match.target.written
                let trailing = String(words[match.end].reversed().prefix { ".,;:!?".contains($0) }.reversed())
                words.replaceSubrange(i...match.end, with: [written + trailing])
            }
            i += 1
        }
        return words.joined(separator: " ")
    }

    /// The target whose spoken form best covers words[start…], preferring longer matches.
    private static func bestMatch(_ words: [String], from start: Int, among candidates: [Target], minimum: Int)
        -> (target: Target, end: Int, partCount: Int)? {
        let first = squash(words[start])
        guard !first.isEmpty else { return nil }
        var best: (target: Target, end: Int, partCount: Int, score: Double, length: Int)?
        // Small function words are never part of a name unless the name itself contains them.
        let glue: Set<String> = ["and", "the", "of", "to", "in", "for", "with", "a", "an", "or", "is", "it", "on", "at", "but", "so", "that", "this",
                                 // List markers must survive for list formatting.
                                 "number", "first", "second", "third", "fourth", "fifth", "sixth", "firstly", "secondly", "thirdly", "finally", "lastly"]
        let listWords: Set<String> = ["number", "first", "second", "third", "fourth", "fifth", "sixth", "firstly", "secondly", "thirdly", "finally", "lastly"]
        // A list word ("number one") may start a name only when the spelling matches exactly ("number input").
        let exactOnly = listWords.contains(first)
        for target in candidates where startsLike(first, target.parts[0]) {
            var spoken = ""
            let maxWords = target.isPath ? 16 : target.parts.count + 3
            var j = start
            while j < min(words.count, start + maxWords) {
                let key = squash(words[j])
                if glue.contains(key), !target.parts.contains(key) { break }
                if !(spokenSeparators.contains(key) && j > start) { spoken += key }
                if !spokenSeparators.contains(key) {
                    for count in stride(from: target.parts.count, through: target.isPath ? min(3, target.parts.count) : target.parts.count, by: -1) {
                        let prefix = target.parts.prefix(count).joined()
                        guard prefix.count >= minimum, abs(prefix.count - spoken.count) <= max(3, prefix.count / 4),
                              endsLike(key, target.parts[count - 1]) else { continue }
                        let spelling = WordDiff.similarity(spoken, prefix)
                        let raw = target.strict ? spelling : max(spelling, WordDiff.similarity(WordDiff.phoneticKey(spoken), WordDiff.phoneticKey(prefix)))
                        guard raw >= (exactOnly ? 1.0 : target.strict ? 0.9 : 0.8), !exactOnly || spelling >= 1.0 else { continue }
                        // Best match first; between near-ties prefer types (Capitalised) and longer names.
                        let score = raw + (target.written.first?.isUppercase == true ? 0.015 : 0) + Double(prefix.count) * 0.001
                        if best == nil || score > best!.score {
                            best = (target, j, count, score, prefix.count)
                        }
                    }
                }
                j += 1
            }
        }
        return best.map { ($0.target, $0.end, $0.partCount) }
    }

    private static func startsLike(_ word: String, _ part: String) -> Bool {
        let n = min(word.count, part.count, 5)
        guard n >= 2 else { return word == part }
        return WordDiff.similarity(String(word.prefix(n)), String(part.prefix(n))) >= 0.6
    }

    private static func endsLike(_ word: String, _ part: String) -> Bool {
        let n = min(word.count, part.count, 5)
        guard n >= 2 else { return word == part }
        return WordDiff.similarity(String(word.suffix(n)), String(part.suffix(n))) >= 0.6
            || WordDiff.similarity(String(word.prefix(n)), String(part.prefix(n))) >= 0.8
            || WordDiff.similarity(WordDiff.phoneticKey(word), WordDiff.phoneticKey(part)) >= 0.6 // "codex" ≈ "context"
    }

    // MARK: - Parts

    /// "/Applications/superwhisper.app/Contents" → ["applications", "superwhisper", "app", "contents"]
    private static func pathParts(_ path: String) -> [String] {
        path.split(whereSeparator: { "/.-_~".contains($0) }).flatMap(camelWords).map(squash).filter { !$0.isEmpty }
    }

    /// Keeps the path up to the end of its `components`-th spoken part, as written:
    /// ("/Applications/superwhisper.app/Contents/Resources/claude-plugin", 6) → ".../Resources/claude".
    private static func prefixPath(_ path: String, components: Int) -> String {
        var count = 0
        var index = path.startIndex
        while index < path.endIndex {
            // Skip separators, then take one run of characters.
            while index < path.endIndex, "/.-_~".contains(path[index]) { index = path.index(after: index) }
            guard index < path.endIndex else { break }
            var runEnd = index
            while runEnd < path.endIndex, !"/.-_~".contains(path[runEnd]) { runEnd = path.index(after: runEnd) }
            count += camelWords(path[index..<runEnd]).count
            if count >= components { return String(path[..<runEnd]) }
            index = runEnd
        }
        return path
    }

    private static func identifierParts(_ identifier: String) -> [String] {
        camelWords(Substring(base(identifier))).map(squash)
    }

    /// "ScreenContext.swift" → "ScreenContext"
    private static func base(_ identifier: String) -> String {
        identifier.split(separator: ".").first.map(String.init) ?? identifier
    }

    private static func isCompoundIdentifier(_ word: String) -> Bool {
        camelWords(Substring(base(word))).count >= 2
    }

    /// "superWhisperApp" → ["super", "Whisper", "App"]
    private static func camelWords(_ s: Substring) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in s {
            if ch.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
