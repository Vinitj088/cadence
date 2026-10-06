import Foundation

/// Finds dictated text inside screen-like text where there's no caret to anchor on, such as a
/// terminal buffer with a TUI input box (Claude Code), wrapped lines and box-drawing borders.
enum FuzzyLocate {
    /// Splits screen text into words, dropping box-drawing, prompt markers and decorations.
    static func words(_ text: String) -> [String] {
        let decoration = CharacterSet(charactersIn: "│┃╭╮╰╯─━┌┐└┘├┤┬┴┼▌▐█▏▕⎿⏺❯›»•·✻✽✢*")
            .union(CharacterSet(charactersIn: "\u{2500}"..."\u{259F}"))
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { decoration.contains($0) ? " " : $0 }))
        return cleaned.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0 != ">" && $0 != "$" && $0 != "%" }
    }

    /// The window of `haystack` that best matches `needle` by word edit distance, with free
    /// gaps before and after it. Ties go to the most recent occurrence (latest on screen).
    static func bestWindow(of needle: [String], in haystack: [String]) -> (range: Range<Int>, distance: Int)? {
        let n = needle.count, m = haystack.count
        guard n > 0, m > 0 else { return nil }
        let a = needle.map(key), b = haystack.map(key)

        // dp[i][j]: cost of matching needle[..<i] ending at haystack[..<j]; start[i][j]: where it began.
        var prev = Array(repeating: 0, count: m + 1)
        var prevStart = Array(0...m)
        for i in 1...n {
            var cur = Array(repeating: 0, count: m + 1)
            var curStart = Array(repeating: 0, count: m + 1)
            cur[0] = i
            curStart[0] = 0
            for j in 1...m {
                let diagonal = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                let up = prev[j] + 1      // needle word missing from screen
                let left = cur[j - 1] + 1 // extra word on screen
                if diagonal <= up, diagonal <= left {
                    cur[j] = diagonal; curStart[j] = prevStart[j - 1]
                } else if up <= left {
                    cur[j] = up; curStart[j] = prevStart[j]
                } else {
                    cur[j] = left; curStart[j] = curStart[j - 1]
                }
            }
            prev = cur
            prevStart = curStart
        }
        var bestEnd = m
        for j in stride(from: m, through: 1, by: -1) where prev[j] < prev[bestEnd] { bestEnd = j }
        let start = prevStart[bestEnd]
        guard bestEnd > start else { return nil }
        return (start..<bestEnd, prev[bestEnd])
    }

    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
