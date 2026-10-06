import Foundation

/// Keeps only what the speaker meant when they correct themselves mid-sentence:
/// "use Postgres, no wait, SQLite" → "use SQLite"; "meet at 3, sorry, I mean at 4" → "meet at 4";
/// "send it to everyone. Scratch that." → "". Agents take prompts literally, so this matters.
/// Only strong cues count; a bare "actually" or "I mean" is ordinary speech.
enum SelfCorrection {
    private static let cues = [
        "no wait", "no, wait", "wait no", "wait, no", "no no", "no, no", "sorry i mean", "sorry, i mean", "sorry i meant",
        "sorry, i meant", "i meant to say", "or rather", "correction", "let me rephrase",
    ]
    private static let scratch = ["scratch that", "delete that", "strike that", "forget that", "ignore that"]

    static func apply(_ text: String) -> String {
        var t = text
        // "… Scratch that." drops the sentence (or clause) just before it.
        for cue in scratch {
            while let r = t.range(of: cue, options: .caseInsensitive) {
                // The sentence being scratched ends just before the cue; find where it began.
                let before = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
                let cut = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) } ?? before.startIndex
                let kept = String(before[..<cut]).trimmingCharacters(in: .whitespaces)
                let after = String(t[r.upperBound...].drop { ".,!? ".contains($0) })
                t = (kept.isEmpty ? "" : kept + " ") + after
                t = t.trimmingCharacters(in: .whitespaces)
            }
        }
        // "X <cue> Y": Y replaces the end of what came before.
        for cue in cues.sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?i)[,.;]?\s*\b"# + NSRegularExpression.escapedPattern(for: cue) + #"\b[,.;]?\s+"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            while let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(match.range, in: t) {
                let before = String(t[..<r.lowerBound])
                let after = String(t[r.upperBound...])
                t = splice(before: before, replacement: after)
            }
        }
        return t
    }

    /// Finds where the corrected phrase starts in `before`: at an earlier copy of the
    /// replacement's first word ("at 3 … at 4"), else it replaces as many words as it has
    /// up to its first pause (at most three).
    private static func splice(before: String, replacement: String) -> String {
        var words = before.split(separator: " ").map(String.init)
        let replacementWords = replacement.split(separator: " ").map(String.init)
        guard let firstNew = replacementWords.first?.lowercased().trimmingCharacters(in: .punctuationCharacters), !words.isEmpty else {
            return before + " " + replacement
        }
        let window = max(0, words.count - 8)
        if let i = words.indices.reversed().first(where: { $0 >= window && words[$0].lowercased().trimmingCharacters(in: .punctuationCharacters) == firstNew }) {
            words.removeSubrange(i...)
        } else {
            // Replace as many words as the new phrase's head ("New York" → "San Francisco"), but always
            // keep the clause's first word ("use Postgres" → "use SQLite", not just "SQLite").
            // A capitalised replacement ("San Francisco") swaps that many words; otherwise one.
            let head = replacementWords.first?.first?.isUppercase == true
                ? replacementWords.prefix { $0.first?.isUppercase == true }.count
                : 1
            let clauseStart = words.lastIndex { $0.last.map { ",.;!?".contains($0) } ?? false }.map { $0 + 1 } ?? 0
            let clauseLength = words.count - clauseStart
            words.removeLast(max(1, min(head, clauseLength - 1, 3)))
        }
        return (words + replacementWords).joined(separator: " ")
    }
}
