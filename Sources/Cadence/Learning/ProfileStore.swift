import Foundation
import FoundationModels
import Observation

/// A short, private profile of the user (people, projects, topics, style), written by Apple's
/// on-device model from their own dictations. It steers transcription, polish and edits toward
/// the user's world. Stored only on this Mac; the user can read, edit or clear it.
@Observable
@MainActor
final class ProfileStore {
    private struct Snapshot: Codable {
        var text = ""
        var updated: Date?
        var dictationsAtUpdate = 0
        var editedByUser = false
    }

    private var snapshot = Snapshot()
    private let url = URL.applicationSupportDirectory.appending(path: "Cadence/profile.json")
    private(set) var isUpdating = false

    var text: String { snapshot.text }
    var updated: Date? { snapshot.updated }

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        }
    }

    /// Names and projects from the profile, for vocabulary.
    var terms: [String] {
        let lines = snapshot.text.split(separator: "\n").filter { $0.hasPrefix("People:") || $0.hasPrefix("Projects:") }
        return lines.flatMap { line in
            line.split(separator: ":", maxSplits: 1).last.map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (").first ?? "" }
            } ?? []
        }
        .filter { !$0.isEmpty && $0.count <= 40 }
    }

    /// A one-line summary for prompts (Whisper, polish, selection edits).
    var promptContext: String? {
        let t = snapshot.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(400))
    }

    func setText(_ text: String) {
        snapshot.text = text
        snapshot.editedByUser = true
        snapshot.updated = .now
        save()
    }

    func clear() {
        snapshot = Snapshot()
        save()
    }

    /// Refreshes the profile when it's stale: every ~25 dictations, or daily.
    func refreshIfNeeded(history: HistoryStore, learning: LearningStore) {
        let count = history.items.count
        guard count >= 15, !isUpdating, !snapshot.editedByUser else { return }
        let stale = snapshot.updated.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        guard stale || count - snapshot.dictationsAtUpdate >= 25 else { return }
        refresh(history: history, learning: learning)
    }

    func refresh(history: HistoryStore, learning: LearningStore) {
        guard SystemLanguageModel.default.availability == .available, !isUpdating else { return }
        isUpdating = true
        // Most recent dictations first, within the on-device model's context budget.
        var budget = 5_000
        var samples: [String] = []
        for item in history.items {
            let line = (item.appName.map { "[\($0)] " } ?? "") + item.text.prefix(300)
            guard budget - line.count > 0 else { break }
            budget -= line.count
            samples.append(line)
        }
        let known = learning.activeTerms.prefix(60).joined(separator: ", ")
        let count = history.items.count
        let previous = snapshot.text

        Task {
            defer { self.isUpdating = false }
            let session = LanguageModelSession(instructions: """
            You maintain a short private profile of a person, used only to help a speech recognizer on their own \
            computer spell their world correctly. From their recent dictations, write at most four lines:
            People: names they mention, with a role in parentheses only if obvious
            Projects: products, companies, codebases, tools
            Topics: recurring subjects and jargon
            Style: how they write (brief)
            Only include what the dictations clearly show. No commentary. Under 110 words.
            """)
            let prompt = """
            Previous profile (update it, keep what still holds):
            \(previous.isEmpty ? "(none)" : previous)

            Words they use: \(known)

            Recent dictations:
            \(samples.joined(separator: "\n"))
            """
            do {
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 220))
                let lines = response.content.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { line in ["People:", "Projects:", "Topics:", "Style:"].contains { line.hasPrefix($0) } }
                guard !lines.isEmpty else { return }
                self.snapshot = Snapshot(text: lines.joined(separator: "\n"), updated: .now, dictationsAtUpdate: count, editedByUser: false)
                self.save()
                logger.notice("profile updated (\(lines.count, privacy: .public) lines)")
            } catch {
                logger.error("profile update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
