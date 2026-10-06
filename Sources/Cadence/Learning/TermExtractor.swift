import AppKit

/// Decides which words are worth teaching the models: names, product and project names,
/// jargon. Ordinary English words are left alone; the models already know them.
@MainActor
enum TermExtractor {
    /// Distinctive tokens in `text`, in order of appearance, without duplicates.
    static func candidates(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var sentenceStart = true
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = clean(String(raw))
            defer { sentenceStart = raw.last.map { ".!?\n".contains($0) } ?? false }
            guard isDistinctive(word, atSentenceStart: sentenceStart), seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
        }
        return result
    }

    static func isDistinctive(_ word: String, atSentenceStart: Bool = false) -> Bool {
        guard (3...32).contains(word.count), word.contains(where: \.isLetter) else { return false }
        guard !word.contains("@"), !word.contains("/"), !word.hasPrefix("http") else { return false }
        // Letters and digits together: M4Pro, GPT5, B2B.
        if word.contains(where: \.isNumber) { return word.filter(\.isLetter).count >= 2 }
        let letters = Array(word)
        // Capitals inside the word: TypeScript, iPhone, GitHub.
        if letters.dropFirst().contains(where: \.isUppercase), letters.contains(where: \.isLowercase) { return true }
        // A capitalised word mid-sentence that isn't an English word: most likely a name.
        if letters[0].isUppercase, !atSentenceStart, letters.dropFirst().allSatisfy({ !$0.isUppercase }) {
            return !isEnglishWord(word)
        }
        return false
    }

    static func isEnglishWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        let range = NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    /// Strips surrounding punctuation and a possessive "'s".
    static func clean(_ word: String) -> String {
        var w = word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "+#")))
        for suffix in ["'s", "’s"] where w.hasSuffix(suffix) { w.removeLast(2) }
        return w
    }
}
