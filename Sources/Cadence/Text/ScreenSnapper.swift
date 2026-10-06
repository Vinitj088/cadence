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

    static func snap(_ text: String, paths: [String], identifiers: [String]) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Longest targets first, so a full path wins over its own fragments.
        let targets: [(written: String, parts: [String], isPath: Bool)] =
            paths.map { ($0, pathParts($0), true) } +
            identifiers.filter(isCompoundIdentifier).map { (base($0), identifierParts($0), false) }
        for target in targets.sorted(by: { $0.parts.joined().count > $1.parts.joined().count }) {
            words = snapOne(words, target: target)
        }
        return words.joined(separator: " ")
    }

    private static func snapOne(_ words: [String], target: (written: String, parts: [String], isPath: Bool)) -> [String] {
        let fullKey = target.parts.joined()
        guard fullKey.count >= (target.isPath ? 10 : 8) else { return words }
        var i = 0
        var out = words
        while i < out.count {
            // A spoken path or name starts with (something like) its first part.
            let first = squash(out[i])
            guard !first.isEmpty, startsLike(first, target.parts[0]) else { i += 1; continue }
            var best: (end: Int, partCount: Int, score: Double)?
            var spoken = ""
            var j = i
            while j < min(out.count, i + 16) {
                let key = squash(out[j])
                if !(spokenSeparators.contains(key) && j > i) { spoken += key }
                // Compare against every prefix of the target's parts: people often say only the start of a path.
                for count in stride(from: target.parts.count, through: target.isPath ? 3 : target.parts.count, by: -1) {
                    let prefix = target.parts.prefix(count).joined()
                    guard prefix.count >= (target.isPath ? 10 : 8), abs(prefix.count - spoken.count) <= max(3, prefix.count / 4) else { continue }
                    let score = max(WordDiff.similarity(spoken, prefix), WordDiff.similarity(WordDiff.phoneticKey(spoken), WordDiff.phoneticKey(prefix)))
                    // …and ends on (something like) the last part it covers.
                    let lastWord = squash(out[j])
                    guard spokenSeparators.contains(lastWord) == false, endsLike(lastWord, target.parts[count - 1]) else { continue }
                    if score >= 0.8, best == nil || count > best!.partCount || (count == best!.partCount && score > best!.score) {
                        best = (j, count, score)
                    }
                }
                j += 1
            }
            if let best, spoken.count > 0 {
                let written = target.isPath ? prefixPath(target.written, components: best.partCount) : target.written
                // Keep punctuation that followed the spoken phrase.
                let trailing = String(out[best.end].reversed().prefix { ".,;:!?".contains($0) }.reversed())
                out.replaceSubrange(i...best.end, with: [written + trailing])
            }
            i += 1
        }
        return out
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
