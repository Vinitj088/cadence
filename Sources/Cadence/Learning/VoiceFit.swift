import Foundation
import Observation

/// Measures every installed model on the user's own voice, using dictations they corrected as
/// ground truth, and recommends the one that makes the fewest mistakes for them.
@Observable
@MainActor
final class VoiceFit {
    struct Score: Codable {
        var errorRate: Double
        var takes: Int
        var date: Date
    }

    private(set) var scores: [String: Score] = [:]
    private(set) var isRunning = false
    private(set) var progress = ""
    private var lastRun: Date?
    private let url = URL.applicationSupportDirectory.appending(path: "Cadence/voicefit.json")

    static let minimumTakes = 5

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Score].self, from: data) {
            scores = decoded
            lastRun = decoded.values.map(\.date).max()
        }
    }

    /// Takes that can be scored: corrected by the user and still holding their recording.
    func samples(in history: HistoryStore) -> [HistoryItem] {
        history.items.filter { $0.hasAudio && ($0.correctedText?.isEmpty == false) }
    }

    /// A clearly better model than the one in use, if the evidence supports it.
    func recommendation(active: String) -> (id: String, improvement: Double)? {
        guard let current = scores[active], current.takes >= Self.minimumTakes else { return nil }
        let best = scores
            .filter { $0.value.takes >= Self.minimumTakes && $0.key != active && ModelStorage.isDownloaded($0.key) }
            .min { $0.value.errorRate < $1.value.errorRate }
        guard let best, current.errorRate > 0 else { return nil }
        let improvement = (current.errorRate - best.value.errorRate) / current.errorRate
        return improvement >= 0.15 ? (best.key, improvement) : nil
    }

    /// Runs in the background when there's enough new evidence and the user is idle.
    func runIfDue(history: HistoryStore, models: ModelManager, transcribe: @escaping (String, [Float]) async throws -> String) {
        guard !isRunning, samples(in: history).count >= Self.minimumTakes else { return }
        if let lastRun, Date().timeIntervalSince(lastRun) < 6 * 3_600 { return }
        run(history: history, models: models, transcribe: transcribe)
    }

    func run(history: HistoryStore, models: ModelManager, transcribe: @escaping (String, [Float]) async throws -> String) {
        let items = Array(samples(in: history).prefix(40))
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        lastRun = .now
        Task {
            defer {
                self.isRunning = false
                self.progress = ""
            }
            for model in ModelCatalog.all where ModelStorage.isDownloaded(model.id) {
                self.progress = "Testing \(model.name)…"
                var errors = 0.0, words = 0.0
                for item in items {
                    guard let audio = history.loadAudio(for: item), let truth = item.correctedText else { continue }
                    guard let hypothesis = try? await transcribe(model.id, audio) else { continue }
                    let n = Double(WordErrorRate.words(truth).count)
                    errors += WordErrorRate.compute(reference: truth, hypothesis: hypothesis) * n
                    words += n
                }
                guard words > 0 else { continue }
                self.scores[model.id] = Score(errorRate: errors / words, takes: items.count, date: .now)
                logger.notice("voice fit \(model.id, privacy: .public): \(errors / words, privacy: .public)")
            }
            if let data = try? JSONEncoder().encode(self.scores) { try? data.write(to: self.url, options: .atomic) }
        }
    }
}
