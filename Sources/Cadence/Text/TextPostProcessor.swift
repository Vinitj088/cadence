import Foundation

/// Deterministic cleanup applied to every transcript, regardless of engine.
struct TextPostProcessor {
    var removeFillers = true
    var smartFormatting = true
    var vocabulary: [String] = []
    var replacements: [Replacement] = []

    func process(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if removeFillers { text = Self.stripFillers(text) }
        text = Self.collapseStutters(text)
        text = applyVocabulary(text)
        text = applyReplacements(text)
        if smartFormatting { text = Self.applyVoiceCommands(text) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Adapts a finished transcript to the text already around the caret: leading space,
    /// first-letter case, and whether a short fragment should keep its full stop.
    func fit(_ text: String, before: String?) -> String {
        guard var result = Optional(text), !result.isEmpty else { return text }
        let preceding = before ?? ""
        let last = preceding.last

        let startsSentence: Bool = {
            let trimmed = preceding.trimmingCharacters(in: .whitespaces)
            guard let end = trimmed.last else { return true }
            return ".!?\n".contains(end) || preceding.hasSuffix("\n")
        }()

        if let last, !last.isWhitespace, !"([{\"'“‘/-@#".contains(last), !result.hasPrefix(",") {
            result = " " + result
        }

        if startsSentence {
            result = Self.capitalizingFirstLetter(result)
        } else if !preceding.isEmpty {
            result = lowercasingFirstWord(result)
            // Dropping into the middle of a sentence: a short fragment shouldn't end it.
            let words = result.split(separator: " ").count
            if words <= 6, result.hasSuffix("."), !result.hasSuffix("...") {
                result.removeLast()
            }
        }
        return result
    }

    // MARK: - Steps

    static func stripFillers(_ text: String) -> String {
        var t = text
        let filler = #"(?i)(?<![\w'])(?:u+m+|u+h+m*|e+r+m+|h+m+|m+h+m+)(?![\w'])[,.…]?\s*"#
        t = t.replacingOccurrences(of: filler, with: "", options: .regularExpression)
        guard t != text else { return text }
        // Tidy what the removal leaves behind: ", ," / leading commas / space before punctuation.
        t = t.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[,.]\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([.!?])\s*,"#, with: "$1", options: .regularExpression)
        // Re-capitalize sentence starts that a removed filler used to occupy.
        t = recapitalizeSentences(t)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "the the" → "the". Limited to short function words, where a repeat is almost always a stumble.
    static func collapseStutters(_ text: String) -> String {
        let words = "i|a|an|the|to|and|but|so|we|you|it|is|in|of|on|that's|i'm|my|for|with|this"
        return text.replacingOccurrences(of: #"(?i)\b("# + words + #")(?:\s+\1\b)+"#, with: "$1", options: .regularExpression)
    }

    /// Spoken formatting commands.
    static func applyVoiceCommands(_ text: String) -> String {
        var t = text
        let rules: [(String, String)] = [
            (#"(?i)[,.]?\s*\bnew paragraph\b[,.]?\s*"#, "\n\n"),
            (#"(?i)[,.]?\s*\bnew line\b[,.]?\s*"#, "\n"),
        ]
        for (pattern, replacement) in rules {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if t.contains("\n") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false)
                .map { capitalizingFirstLetter(String($0).trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
        }
        return t
    }

    /// Fixes the casing and spacing of known terms: "type script" / "Typescript" → "TypeScript".
    func applyVocabulary(_ text: String) -> String {
        guard !vocabulary.isEmpty else { return text }
        var t = text
        for term in vocabulary where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            let letters = term.filter { $0.isLetter || $0.isNumber }
            guard letters.count >= 2 else { continue }
            // Allow the engine to have split the term with spaces or hyphens anywhere.
            let pattern = letters.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s\-]?"#)
            t = t.replacingOccurrences(of: #"(?i)(?<![\w])"# + pattern + #"(?![\w])"#, with: NSRegularExpression.escapedTemplate(for: term), options: .regularExpression)
        }
        return t
    }

    func applyReplacements(_ text: String) -> String {
        var t = text
        for rule in replacements where !rule.spoken.isEmpty {
            let pattern = #"(?i)(?<![\w])"# + NSRegularExpression.escapedPattern(for: rule.spoken) + #"(?![\w])"#
            t = t.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: rule.written), options: .regularExpression)
        }
        return t
    }

    // MARK: - Casing helpers

    static func capitalizingFirstLetter(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    private func lowercasingFirstWord(_ s: String) -> String {
        let trimmed = s.drop(while: \.isWhitespace)
        let word = trimmed.prefix(while: { !$0.isWhitespace && !",.!?;:".contains($0) })
        guard let first = word.first, first.isUppercase else { return s }
        // Keep "I", "I'm", acronyms ("API"), and anything the user told us is a proper noun.
        if word == "I" || word.hasPrefix("I'") || word.dropFirst().contains(where: \.isUppercase) { return s }
        if vocabulary.contains(where: { $0.caseInsensitiveCompare(String(word)) == .orderedSame }) { return s }
        if Self.likelyProperNoun(String(word)) { return s }
        let start = s.firstIndex(of: first)!
        return s.replacingCharacters(in: start...start, with: first.lowercased())
    }

    private static func likelyProperNoun(_ word: String) -> Bool {
        let tagger = NSLinguisticTagger(tagSchemes: [.nameType], options: 0)
        tagger.string = word
        let tag = tagger.tag(at: 0, scheme: .nameType, tokenRange: nil, sentenceRange: nil)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    private static func recapitalizeSentences(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
                continue
            }
            out.append(ch)
            if ".!?".contains(ch) { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
        }
        return out
    }
}
