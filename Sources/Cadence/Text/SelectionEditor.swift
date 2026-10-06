import Foundation
import FoundationModels

/// "Talk to the selection": applies a spoken instruction to selected text with Apple's
/// on-device model ("make this more concise", "turn this into bullet points").
enum SelectionEditor {
    private static let verbs: Set<String> = [
        "make", "rewrite", "rephrase", "translate", "summarize", "summarise", "shorten", "expand", "fix", "turn", "convert",
        "change", "format", "add", "remove", "replace", "reply", "respond", "simplify", "polish", "correct", "proofread",
        "improve", "edit", "clean", "tidy", "condense", "elaborate", "explain", "capitalize", "lowercase", "uppercase",
        "bullet", "number", "sort", "reorder", "split", "merge", "combine", "draft", "write", "tone", "soften", "tighten",
    ]

    /// Whether what was said is an instruction about the selection rather than replacement text.
    static func isInstruction(_ utterance: String) -> Bool {
        let words = utterance.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first, words.count <= 40 else { return false }
        let lead = ["please", "can", "could", "would", "now", "just", "ok", "okay", "cadence"].contains(first) ? Array(words.drop { ["please", "can", "could", "would", "you", "now", "just", "ok", "okay", "cadence"].contains($0) }) : words
        guard let verb = lead.first else { return false }
        return verbs.contains(verb) || (verb == "this" && lead.count > 1 && ["should", "needs", "could"].contains(lead[1]))
    }

    static func edit(_ selection: String, instruction: String, appName: String?, profile: String?) async throws -> String {
        guard SystemLanguageModel.default.availability == .available else {
            throw EngineError.unavailable(Polisher.unavailableReason ?? "Apple's on-device model isn't available")
        }
        var instructions = """
        You edit text for the user. Apply their instruction to the text between <text> tags and return only \
        the resulting text, with no preamble, quotes, tags or explanation. Keep their meaning and voice unless \
        the instruction asks otherwise. Preserve line breaks and formatting where it makes sense.
        """
        if let profile, !profile.isEmpty { instructions += "\n\nAbout the user: \(profile)" }
        if let appName { instructions += "\n\nThe text is in \(appName)." }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Instruction: \(instruction)\n\n<text>\n\(selection)\n</text>"
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: max(256, selection.count / 2 + 200))

        let result = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await session.respond(to: prompt, options: options).content }
            group.addTask { try await Task.sleep(for: .seconds(20)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard var text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw EngineError.unavailable("The edit took too long")
        }
        text = text.replacingOccurrences(of: "</?text>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
