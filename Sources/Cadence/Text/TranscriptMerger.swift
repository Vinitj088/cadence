import Foundation

/// Combines two transcripts of the same audio: the primary (more accurate overall) and a
/// companion that can use the user's vocabulary while decoding. Disagreements are settled
/// per span, in favour of whichever version contains the user's words or real words.
@MainActor
enum TranscriptMerger {
    struct Decision { var primary: String; var companion: String }

    static func merge(primary: String, companion: String, vocabulary: [String]) -> (text: String, decisions: [Decision]) {
        let a = primary.split(separator: " ").map(String.init)
        let b = companion.split(separator: " ").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return (primary, []) }
        let na = a.map(key), nb = b.map(key)

        // Word alignment (edit distance).
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        for i in 1...max(a.count, 1) {
            for j in 1...max(b.count, 1) {
                dp[i][j] = na[i - 1] == nb[j - 1] ? dp[i - 1][j - 1] : min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1]) + 1
            }
        }
        // Too different to merge safely (e.g. one model hallucinated or dropped a lot).
        guard Double(dp[a.count][b.count]) <= Double(a.count) * 0.5 else { return (primary, []) }

        // Walk back into equal words and disagreement spans.
        var segments: [(ArraySlice<String>, ArraySlice<String>, Bool)] = []
        var i = a.count, j = b.count
        var spanA = i, spanB = j, inSpan = false
        func closeSpan() {
            if inSpan { segments.append((a[i..<spanA], b[j..<spanB], false)) }
            inSpan = false
        }
        while i > 0 || j > 0 {
            if i > 0, j > 0, na[i - 1] == nb[j - 1], dp[i][j] == dp[i - 1][j - 1] {
                closeSpan()
                segments.append((a[(i - 1)..<i], b[(j - 1)..<j], true))
                i -= 1; j -= 1
                continue
            }
            if !inSpan { spanA = i; spanB = j; inSpan = true }
            if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 { i -= 1; j -= 1 }
            else if i > 0, dp[i][j] == dp[i - 1][j] + 1 { i -= 1 }
            else { j -= 1 }
        }
        closeSpan()
        segments.reverse()

        let vocab = Set(vocabulary.map { key($0) })
        var out: [String] = []
        var decisions: [Decision] = []
        for (pa, pb, equal) in segments {
            if equal || pb.isEmpty { out.append(contentsOf: pa); continue }
            if choosesCompanion(Array(pa), Array(pb), vocab: vocab) {
                out.append(contentsOf: pb)
                decisions.append(Decision(primary: pa.joined(separator: " "), companion: pb.joined(separator: " ")))
            } else {
                out.append(contentsOf: pa)
            }
        }
        return (out.joined(separator: " "), decisions)
    }

    private static func choosesCompanion(_ p: [String], _ c: [String], vocab: Set<String>) -> Bool {
        guard c.count <= 4, p.count <= 4 else { return false }
        let pKeys = p.map(key), cKeys = c.map(key)
        // The companion heard one of the user's words that the primary missed.
        let joinedC = cKeys.joined(), joinedP = pKeys.joined()
        if cKeys.contains(where: vocab.contains) || vocab.contains(joinedC), !pKeys.contains(where: vocab.contains), !vocab.contains(joinedP) {
            return true
        }
        // The primary produced a non-word where the companion heard real words that sound the same.
        let pHasNonWord = p.contains { w in let k = TermExtractor.clean(w); return k.count >= 3 && !TermExtractor.isEnglishWord(k) && !vocab.contains(key(w)) }
        let cAllWords = c.allSatisfy { w in let k = TermExtractor.clean(w); return k.isEmpty || TermExtractor.isEnglishWord(k) }
        if pHasNonWord, cAllWords, WordDiff.soundSimilarity(joinedP, joinedC) >= 0.6 { return true }
        return false
    }

    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
