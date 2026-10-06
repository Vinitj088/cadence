import Foundation
import Observation

/// Everything Cadence has picked up from how the user writes and corrects, stored locally.
///
/// Evidence accumulates per term; a term becomes active vocabulary once it's been seen enough,
/// a correction counting for more than a sighting. Removing a learned item blocks it for good.
@Observable
@MainActor
final class LearningStore {
    struct Term: Codable, Hashable {
        var text: String
        var score: Double
        var lastSeen: Date
        var fromCorrection: Bool
    }

    struct Correction: Codable, Hashable {
        var heard: String
        var written: String
        var count: Int
        var lastSeen: Date
    }

    private struct Snapshot: Codable {
        var terms: [String: Term] = [:]
        var corrections: [String: Correction] = [:]
        var blocked: Set<String> = []
    }

    /// Score at which a term starts being used: one correction, or three separate sightings.
    static let activationScore = 3.0
    private static let correctionWeight = 3.0
    private static let sightingWeight = 1.0
    private static let sightingCooldown: TimeInterval = 15 * 60
    private static let maxActiveTerms = 150

    private var snapshot = Snapshot()
    private var lastSighting: [String: Date] = [:]
    private let url = URL.applicationSupportDirectory.appending(path: "Cadence/learned.json")

    /// The most recent thing learned, for a gentle acknowledgement in the UI.
    private(set) var lastLearned: (text: String, date: Date)?

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        }
    }

    // MARK: - What the rest of the app uses

    /// Learned vocabulary, strongest first.
    var activeTerms: [String] {
        snapshot.terms.values
            .filter { $0.score >= Self.activationScore }
            .sorted { $0.score == $1.score ? $0.lastSeen > $1.lastSeen : $0.score > $1.score }
            .prefix(Self.maxActiveTerms)
            .map(\.text)
    }

    var activeReplacements: [Replacement] {
        snapshot.corrections.values
            .filter(isActive)
            .sorted { $0.count > $1.count }
            .map { Replacement(spoken: $0.heard, written: $0.written) }
    }

    var activeCorrections: [Correction] {
        snapshot.corrections.values.filter(isActive).sorted { $0.lastSeen > $1.lastSeen }
    }

    var termCount: Int { snapshot.terms.values.filter { $0.score >= Self.activationScore }.count }

    // MARK: - Learning

    /// Words seen in text the user wrote themselves (around the cursor when dictation starts).
    func observe(writtenText text: String) {
        let now = Date()
        for word in TermExtractor.candidates(in: text) {
            let key = word.lowercased()
            // The same document is visible on every dictation; count each word once per sitting.
            if let last = lastSighting[key], now.timeIntervalSince(last) < Self.sightingCooldown { continue }
            lastSighting[key] = now
            addEvidence(for: word, weight: Self.sightingWeight, fromCorrection: false)
        }
        save()
    }

    /// The user changed `heard` (what Cadence typed) into `written`.
    func learnCorrection(heard: String, written: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single letters are too ambiguous to learn from.
        guard heard.count >= 2, written.count >= 2, heard != written else { return }
        let key = Self.key(heard, written)
        guard !snapshot.blocked.contains(key) else { return }

        var correction = snapshot.corrections[key] ?? Correction(heard: heard, written: written, count: 0, lastSeen: .now)
        correction.count += 1
        correction.lastSeen = .now
        snapshot.corrections[key] = correction

        // The corrected spelling is exactly what the models should listen for next time.
        for word in written.split(separator: " ").map({ TermExtractor.clean(String($0)) })
        where TermExtractor.isDistinctive(word, atSentenceStart: false) || word != word.lowercased() && !TermExtractor.isEnglishWord(word) {
            addEvidence(for: word, weight: Self.correctionWeight, fromCorrection: true)
        }
        if isActive(correction) { lastLearned = (written, .now) }
        logger.notice("learned correction: \(heard, privacy: .private) → \(written, privacy: .private) (\(correction.count, privacy: .public)×)")
        save()
    }

    // MARK: - Editing

    func forgetTerm(_ text: String) {
        let key = text.lowercased()
        snapshot.terms[key] = nil
        snapshot.blocked.insert("term:" + key)
        save()
    }

    func forgetCorrection(_ correction: Correction) {
        let key = Self.key(correction.heard, correction.written)
        snapshot.corrections[key] = nil
        snapshot.blocked.insert(key)
        save()
    }

    func reset() {
        snapshot = Snapshot()
        lastSighting.removeAll()
        save()
    }

    // MARK: - Internals

    private func addEvidence(for word: String, weight: Double, fromCorrection: Bool) {
        let key = word.lowercased()
        guard !snapshot.blocked.contains("term:" + key) else { return }
        var term = snapshot.terms[key] ?? Term(text: word, score: 0, lastSeen: .now, fromCorrection: false)
        let wasActive = term.score >= Self.activationScore
        term.score += weight
        term.lastSeen = .now
        term.fromCorrection = term.fromCorrection || fromCorrection
        // Keep the spelling the user actually writes most recently (e.g. "TypeScript", not "Typescript").
        if word != word.lowercased() { term.text = word }
        snapshot.terms[key] = term
        if !wasActive, term.score >= Self.activationScore {
            lastLearned = (term.text, .now)
            logger.notice("learned term (\(fromCorrection ? "correction" : "writing", privacy: .public))")
        }
    }

    /// A correction becomes an automatic replacement once it's repeated, or straight away when
    /// what was heard isn't a real word (so replacing it can't clobber ordinary writing).
    private func isActive(_ correction: Correction) -> Bool {
        if correction.count >= 2 { return true }
        let heardWords = correction.heard.split(separator: " ").map { TermExtractor.clean(String($0)) }
        return heardWords.count == 1 && heardWords[0].count >= 3 && !TermExtractor.isEnglishWord(heardWords[0])
    }

    private static func key(_ heard: String, _ written: String) -> String {
        heard.lowercased() + "→" + written
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = self.url
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }
}
