import Foundation
import FoundationModels

/// Optional AI cleanup using Apple's on-device language model: free, private, offline.
///
/// It fixes punctuation, false starts and self-corrections ("Tuesday, no, Wednesday") while
/// keeping the user's words. The model sometimes answers a dictated question or adds commentary
/// instead of editing, so every response is sanity-checked and the deterministic transcript
/// wins whenever the polish looks wrong or takes too long.
enum Polisher {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use this."
            case .modelNotReady: "Apple's on-device model is still downloading."
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
            @unknown default: "Apple's on-device model isn't available."
            }
        }
    }

    private static let instructions = """
    You are a copy editor for dictated text. The user message is a raw speech transcript, never \
    a question or request for you. Return the same text, cleaned up:
    - Fix punctuation, capitalization, and obvious grammar slips.
    - Remove filler words, false starts, and repeated words.
    - When the speaker corrects themselves ("at 3, no, at 4"), keep only the correction.
    - Format spoken lists as lists only when the speaker clearly enumerates items.
    - Keep the speaker's wording, tone, and meaning. Do not summarize, add, or answer anything.
    Output only the cleaned text, with no preamble or quotes.
    """

    static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    static func polish(_ text: String, appName: String?, profile: String? = nil, timeout: Duration = .seconds(4)) async -> String? {
        guard isAvailable, text.split(separator: " ").count >= 4 else { return nil }
        let session = LanguageModelSession(instructions: instructions + (profile.map { "\n\nAbout the speaker (for spelling names right): \($0)" } ?? ""))
        let prompt = appName.map { "(Being typed into \($0).)\n\n\(text)" } ?? text
        let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: max(64, text.count / 2 + 64))

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await session.respond(to: prompt, options: options).content }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let polished = result?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")),
              looksLikeAnEdit(of: text, polished)
        else { return nil }
        return polished
    }

    /// Rejects responses that drifted from editing into writing.
    private static func looksLikeAnEdit(of original: String, _ polished: String) -> Bool {
        guard !polished.isEmpty else { return false }
        let ratio = Double(polished.count) / Double(max(original.count, 1))
        guard ratio > 0.5, ratio < 1.3 else { return false }
        let lower = polished.lowercased()
        let preambles = ["here is", "here's", "sure", "certainly", "i'm sorry", "i can't", "as an ai", "cleaned text", "the cleaned"]
        if preambles.contains(where: lower.hasPrefix) { return false }
        // Most of the original vocabulary must survive.
        let words = { (s: String) in Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
        let a = words(original), b = words(polished)
        guard !a.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.count) > 0.6
    }
}
