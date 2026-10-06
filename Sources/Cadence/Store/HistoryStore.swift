import AVFoundation
import Foundation
import Observation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    /// What was inserted.
    var text: String
    /// What the engine produced before cleanup, for comparison.
    var rawText: String
    var modelID: String
    var audioSeconds: Double
    var processingSeconds: Double
    var appName: String?
    var hasAudio = false

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

@Observable
final class HistoryStore {
    private(set) var items: [HistoryItem] = []

    let directory: URL
    private var fileURL: URL { directory.appending(path: "history.json") }
    var audioDirectory: URL { directory.appending(path: "Audio", directoryHint: .isDirectory) }

    init() {
        directory = URL.applicationSupportDirectory.appending(path: "Cadence", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
        pruneAudio(olderThan: 14)
    }

    func add(_ item: HistoryItem, audio: [Float]?) {
        var item = item
        if let audio, !audio.isEmpty {
            item.hasAudio = (try? Self.writeWAV(audio, to: audioURL(for: item.id))) != nil
        }
        items.insert(item, at: 0)
        save()
    }

    func update(_ item: HistoryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids { try? FileManager.default.removeItem(at: audioURL(for: id)) }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        delete(Set(items.map(\.id)))
    }

    func audioURL(for id: UUID) -> URL {
        audioDirectory.appending(path: "\(id.uuidString).wav")
    }

    func loadAudio(for item: HistoryItem) -> [Float]? {
        guard item.hasAudio, let file = try? AVAudioFile(forReading: audioURL(for: item.id)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: - Stats

    var totalWords: Int { items.reduce(0) { $0 + $1.wordCount } }
    var totalAudioSeconds: Double { items.reduce(0) { $0 + $1.audioSeconds } }

    /// Speaking pace across all dictations.
    var wordsPerMinute: Int {
        guard totalAudioSeconds > 10 else { return 0 }
        return Int(Double(totalWords) / (totalAudioSeconds / 60))
    }

    /// Time saved versus typing at 40 wpm.
    var minutesSaved: Double {
        let typing = Double(totalWords) / 40
        let speaking = totalAudioSeconds / 60
        return max(0, typing - speaking)
    }

    var streakDays: Int {
        let calendar = Calendar.current
        let days = Set(items.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = items
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func pruneAudio(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var changed = false
        for i in items.indices where items[i].hasAudio && items[i].date < cutoff {
            try? FileManager.default.removeItem(at: audioURL(for: items[i].id))
            items[i].hasAudio = false
            changed = true
        }
        if changed { save() }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
