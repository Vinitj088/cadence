import Foundation

enum WordErrorRate {
    /// Word-level edit distance divided by reference length, ignoring case and punctuation.
    static func compute(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in 1...max(h.count, 1) where !h.isEmpty {
                let cost = r[i - 1] == h[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
