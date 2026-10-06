import AppKit
import ApplicationServices

/// Notices when the user fixes text Cadence just typed.
///
/// After a paste it remembers the field and its contents, then re-reads the field a few times
/// over the next minute (and whenever the next dictation starts). The difference, narrowed to
/// the inserted span, is aligned word by word; small mishearing-style fixes become corrections,
/// while wholesale rewrites are ignored.
@MainActor
final class CorrectionWatcher {
    var onCorrection: ((_ heard: String, _ written: String) -> Void)?

    private struct Watch {
        let element: AXUIElement
        var baseline: NSString
        var range: NSRange
        var id = UUID()
    }

    /// For terminals: no caret to anchor on, so the latest best match on screen is the text.
    private struct ScreenWatch {
        let element: AXUIElement
        var inserted: [String]
        var id = UUID()
    }

    private var watch: Watch?
    private var screenWatch: ScreenWatch?
    private let checkTimes: [Double] = [5, 15, 35, 70]

    /// Starts watching `inserted` on a screen-like element (a terminal), where it's found by matching.
    func watchScreen(_ inserted: String, in element: AXUIElement) {
        checkNow()
        watch = nil
        let words = FuzzyLocate.words(inserted)
        guard words.count >= 2 else { screenWatch = nil; return }
        let started = ScreenWatch(element: element, inserted: words)
        screenWatch = started
        for delay in checkTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.screenWatch?.id == started.id else { return }
                self?.checkScreen()
            }
        }
    }

    private func checkScreen() {
        guard var current = screenWatch, let buffer: String = current.element.attribute(kAXValueAttribute) else { return }
        // Only the recent part of the scrollback can contain what was just dictated.
        let haystack = FuzzyLocate.words(String(buffer.suffix(12_000)))
        guard let match = FuzzyLocate.bestWindow(of: current.inserted, in: haystack) else { return }
        let n = current.inserted.count
        // Unchanged, or nothing on screen resembles it any more (cleared, scrolled away).
        guard match.distance > 0, Double(match.distance) <= max(3, Double(n) * 0.5) else { return }
        let found = Array(haystack[match.range])
        for (heard, written) in WordDiff.corrections(from: current.inserted.joined(separator: " "), to: found.joined(separator: " ")) {
            onCorrection?(heard, written)
        }
        current.inserted = found
        screenWatch = current
    }

    /// Starts watching `inserted`, which was just pasted into `element`.
    func watch(_ inserted: String, in element: AXUIElement) {
        checkNow()
        watch = nil
        screenWatch = nil
        // Give the target app a moment to apply the paste before taking the baseline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let value: String = element.attribute(kAXValueAttribute) else { return }
            let baseline = value as NSString
            guard let range = Self.locate(inserted, in: baseline, element: element) else { return }
            let started = Watch(element: element, baseline: baseline, range: range)
            self.watch = started
            for delay in self.checkTimes {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard self?.watch?.id == started.id else { return }
                    self?.checkNow()
                }
            }
        }
    }

    /// Compares the field with the baseline and reports any corrections inside the inserted text.
    func checkNow() {
        if screenWatch != nil { checkScreen() }
        guard var current = watch, let value: String = current.element.attribute(kAXValueAttribute) else { return }
        let now = value as NSString
        let before = current.baseline
        guard !now.isEqual(to: before as String) else { return }

        // Isolate the edited region with the longest common prefix and suffix.
        let limit = min(before.length, now.length)
        var prefix = 0
        while prefix < limit, before.character(at: prefix) == now.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, before.character(at: before.length - 1 - suffix) == now.character(at: now.length - 1 - suffix) { suffix += 1 }

        let changedBefore = NSRange(location: prefix, length: before.length - suffix - prefix)
        let inserted = current.range
        // An edit somewhere else in the document says nothing about our transcript.
        guard NSIntersectionRange(changedBefore, NSRange(location: inserted.location - 1, length: inserted.length + 2)).length > 0
            || (changedBefore.length == 0 && NSLocationInRange(prefix, inserted))
        else {
            // Still track where our text sits if the user typed before it.
            if changedBefore.location + changedBefore.length <= inserted.location {
                current.range.location += now.length - before.length
                current.baseline = now
                watch = current
            }
            return
        }

        // Compare the inserted span (widened to whatever the edit touched) before and after.
        let start = min(inserted.location, changedBefore.location)
        let endBefore = max(NSMaxRange(inserted), NSMaxRange(changedBefore))
        let endNow = endBefore + (now.length - before.length)
        guard endNow >= start, endNow <= now.length else { return }
        let oldText = before.substring(with: NSRange(location: start, length: endBefore - start))
        let newText = now.substring(with: NSRange(location: start, length: endNow - start))

        for (heard, written) in WordDiff.corrections(from: oldText, to: newText) {
            onCorrection?(heard, written)
        }

        // Keep watching the corrected text so a later edit isn't counted twice.
        current.baseline = now
        current.range = NSRange(location: start, length: endNow - start)
        watch = current
    }

    /// Finds the pasted text in the field, preferring the occurrence that ends at the caret.
    private static func locate(_ inserted: String, in value: NSString, element: AXUIElement) -> NSRange? {
        let needle = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let rangeValue: AXValue = element.attribute(kAXSelectedTextRangeAttribute) {
            var caret = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &caret) {
                let end = min(caret.location, value.length)
                let window = NSRange(location: 0, length: end)
                let found = value.range(of: needle, options: .backwards, range: window)
                if found.location != NSNotFound, NSMaxRange(found) >= end - 2 { return found }
            }
        }
        let found = value.range(of: needle, options: .backwards)
        return found.location == NSNotFound ? nil : found
    }
}

/// Word-level alignment between two versions of a short text.
enum WordDiff {
    /// Small, mishearing-shaped replacements between `old` and `new`, e.g. ("cooper netties", "Kubernetes").
    static func corrections(from old: String, to new: String) -> [(String, String)] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty, !b.isEmpty, a.count <= 80, b.count <= 100 else { return [] }

        // Levenshtein over words, comparing without punctuation so "you," matches "you".
        let na = a.map(normalize), nb = b.map(normalize)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dp[i][0] = i }
        for j in 0...b.count { dp[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = na[i - 1] == nb[j - 1] && a[i - 1] == b[j - 1]
                    ? dp[i - 1][j - 1]
                    : min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1]) + 1
            }
        }
        // Most of the text changing is a rewrite, not a correction.
        guard Double(dp[a.count][b.count]) <= max(3, Double(a.count) * 0.6) else { return [] }

        // Walk back, grouping consecutive differences into chunks.
        var chunks: [(Range<Int>, Range<Int>)] = []
        var i = a.count, j = b.count
        var chunkA: Int?, chunkB: Int?
        func close() {
            if let ea = chunkA, let eb = chunkB { chunks.append((i..<ea, j..<eb)) }
            chunkA = nil; chunkB = nil
        }
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], dp[i][j] == dp[i - 1][j - 1] {
                close()
                i -= 1; j -= 1
                continue
            }
            if chunkA == nil { chunkA = i; chunkB = j }
            if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 { i -= 1; j -= 1 }
            else if i > 0, dp[i][j] == dp[i - 1][j] + 1 { i -= 1 }
            else { j -= 1 }
        }
        close()

        var result: [(String, String)] = []
        for (ra, rb) in chunks where !ra.isEmpty && !rb.isEmpty && ra.count <= 8 && rb.count <= 8 {
            for (heard, written) in pairUp(Array(a[ra]), Array(b[rb])) {
                let h = trimPunctuation(heard), w = trimPunctuation(written)
                if !h.isEmpty, !w.isEmpty, h != w { result.append((h, w)) }
            }
        }
        return result
    }

    /// Splits a changed run into the best-matching pieces: one word for one, or up to three
    /// words merged into one (or one split into two), so "type script and roid" against
    /// "TypeScript Android" yields two separate fixes. Pieces must sound alike to count.
    private static func pairUp(_ a: [String], _ b: [String]) -> [(String, String)] {
        // (0, 1) and (1, 0) let a word be added or dropped alongside a fix ("a Lexandra" → "Alexandra sir").
        let shapes = [(1, 1), (2, 1), (3, 1), (1, 2), (0, 1), (1, 0)]
        var best = Array(repeating: Array(repeating: -Double.infinity, count: b.count + 1), count: a.count + 1)
        var step = Array(repeating: Array(repeating: (0, 0), count: b.count + 1), count: a.count + 1)
        best[0][0] = 0
        for i in 0...a.count {
            for j in 0...b.count where best[i][j] > -.infinity {
                for (ka, kb) in shapes where i + ka <= a.count && j + kb <= b.count {
                    let x = squash(a[i..<i + ka].joined()), y = squash(b[j..<j + kb].joined())
                    let score = best[i][j] + (ka == 0 || kb == 0 ? -0.3 : soundSimilarity(x, y) - 0.5)
                    if score > best[i + ka][j + kb] {
                        best[i + ka][j + kb] = score
                        step[i + ka][j + kb] = (ka, kb)
                    }
                }
            }
        }
        guard best[a.count][b.count] > -.infinity else { return [] }
        var pairs: [(String, String)] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            let (ka, kb) = step[i][j]
            let heard = a[i - ka..<i].joined(separator: " "), written = b[j - kb..<j].joined(separator: " ")
            if ka > 0, kb > 0, soundSimilarity(squash(heard), squash(written)) >= 0.5 { pairs.append((heard, written)) }
            i -= ka; j -= kb
        }
        return pairs.reversed()
    }

    private static func squash(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: " ", with: "")
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
    }

    private static func trimPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”()"))
    }

    /// How alike two strings are as spoken: the better of their spelling similarity and the
    /// similarity of their phonetic keys. "happy now" and "habanero" look different but sound alike.
    static func soundSimilarity(_ x: String, _ y: String) -> Double {
        max(similarity(x, y), similarity(phoneticKey(x), phoneticKey(y)))
    }

    /// A rough English sound skeleton: merge digraphs, drop silent-ish h/w, fold voiced and
    /// unvoiced pairs (b/p, d/t, g/k, v/f, z/s), reduce every vowel to one, collapse repeats.
    static func phoneticKey(_ s: String) -> String {
        var t = s.lowercased().filter(\.isLetter)
        for (from, to) in [("ph", "f"), ("bh", "b"), ("dh", "d"), ("kh", "k"), ("gh", "g"), ("th", "t"), ("sh", "s"), ("ch", "c"), ("ck", "k"), ("qu", "k"), ("x", "ks")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        let map: [Character: Character] = [
            "b": "p", "d": "t", "g": "k", "v": "f", "z": "s", "c": "k", "q": "k", "j": "c",
            "a": "a", "e": "a", "i": "a", "o": "a", "u": "a", "y": "a",
        ]
        var out: [Character] = []
        for ch in t where ch != "h" && ch != "w" {
            let mapped = map[ch] ?? ch
            if out.last != mapped { out.append(mapped) }
        }
        return String(out)
    }

    /// 1 − normalised character edit distance.
    static func similarity(_ x: String, _ y: String) -> Double {
        let a = Array(x), b = Array(y)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count, 1))
    }
}
