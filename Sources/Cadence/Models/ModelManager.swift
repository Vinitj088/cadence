import Foundation
import Observation

/// Owns model downloads, the loaded engine, and per-model state for the UI.
@Observable
@MainActor
final class ModelManager {
    enum Status: Equatable {
        case notDownloaded
        case downloading(Double, String)
        case downloaded
        case loading(Double, String)
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            default: false
            }
        }
    }

    private(set) var status: [String: Status] = [:]
    private(set) var activeEngine: (any TranscriptionEngine)?
    private(set) var activeModelID: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        refreshDiskState()
    }

    func status(of id: String) -> Status {
        status[id] ?? .notDownloaded
    }

    var activeIsReady: Bool {
        guard let activeModelID else { return false }
        return status(of: activeModelID) == .ready
    }

    func refreshDiskState() {
        for model in ModelCatalog.all where !(status[model.id]?.isBusy ?? false) && status[model.id] != .ready {
            status[model.id] = ModelStorage.isDownloaded(model.id) ? .downloaded : .notDownloaded
        }
    }

    /// Makes `id` the engine used for dictation, downloading and loading it as needed.
    func activate(_ id: String) {
        let model = ModelCatalog.info(id)
        // Already loaded or already on its way: a second download into the same folder
        // would race the first and leave half-written weights behind.
        if activeModelID == id, status(of: id) == .ready || status(of: id).isBusy || tasks[id] != nil { return }

        let previous = activeEngine
        let previousID = activeModelID
        activeModelID = id
        activeEngine = nil
        if let previous {
            Task { await previous.unload() }
        }
        if let previousID, previousID != id {
            tasks[previousID]?.cancel()
            tasks[previousID] = nil
            status[previousID] = ModelStorage.isDownloaded(previousID) ? .downloaded : .notDownloaded
        }

        generation += 1
        let attempt = generation
        let pendingDownload = tasks[id]
        tasks[id] = Task { [weak self] in
            // If "Download" was already running for this model, let it finish rather than start a second copy.
            await pendingDownload?.value
            var lastError: Error?
            // A failed load usually means an interrupted download; the second try starts from a clean folder.
            for retry in 0..<2 {
                guard let self, self.generation == attempt else { return }
                if retry == 1 { ModelStorage.delete(id) }
                let engine = EngineFactory.make(for: model)
                let wasDownloaded = ModelStorage.isDownloaded(id) || model.family == .apple
                self.status[id] = wasDownloaded ? .loading(0, "Loading") : .downloading(0, "Starting")
                do {
                    try await engine.prepare { fraction, label in
                        Task { @MainActor in
                            guard self.generation == attempt, self.status(of: id).isBusy else { return }
                            self.status[id] = Self.isDownloadLabel(label) ? .downloading(fraction, label) : .loading(fraction, label)
                        }
                    }
                    guard self.generation == attempt, self.activeModelID == id else {
                        await engine.unload()
                        return
                    }
                    self.activeEngine = engine
                    self.status[id] = .ready
                    logger.notice("model \(id, privacy: .public) ready")
                    self.tasks[id] = nil
                    return
                } catch {
                    lastError = error
                    logger.error("loading \(id, privacy: .public) failed (attempt \(retry + 1)): \(String(describing: error), privacy: .public)")
                    if Task.isCancelled || model.family == .apple { break }
                }
            }
            guard let self, self.generation == attempt else { return }
            self.status[id] = .failed(lastError.map(Self.describe) ?? "Couldn't load the model")
            self.tasks[id] = nil
        }
    }

    private var generation = 0

    private static func isDownloadLabel(_ label: String) -> Bool {
        label.hasPrefix("Downloading") || label.hasPrefix("Preparing download") || label.hasPrefix("Starting")
    }


    /// Downloads a model without switching to it.
    func download(_ id: String) {
        guard !status(of: id).isBusy else { return }
        let model = ModelCatalog.info(id)
        status[id] = .downloading(0, "Starting")
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let engine = EngineFactory.make(for: model)
            do {
                try await engine.prepare { fraction, label in
                    Task { @MainActor in
                        guard self.status(of: id).isBusy else { return }
                        self.status[id] = .downloading(fraction, label)
                    }
                }
                await engine.unload()
                self.status[id] = .downloaded
            } catch {
                self.status[id] = .failed(Self.describe(error))
            }
            self.tasks[id] = nil
        }
    }

    func cancel(_ id: String) {
        generation += 1
        tasks[id]?.cancel()
        tasks[id] = nil
        status[id] = ModelStorage.isDownloaded(id) ? .downloaded : .notDownloaded
    }

    func delete(_ id: String) {
        guard id != activeModelID else { return }
        cancel(id)
        ModelStorage.delete(id)
        status[id] = .notDownloaded
    }

    /// Loads a model's engine on its own, for side-by-side comparisons. The caller unloads it.
    func temporaryEngine(for id: String) async throws -> any TranscriptionEngine {
        if id == activeModelID, let activeEngine { return activeEngine }
        let engine = EngineFactory.make(for: ModelCatalog.info(id))
        try await engine.prepare { _, _ in }
        return engine
    }

    private static func describe(_ error: Error) -> String {
        if (error as? URLError)?.code == .notConnectedToInternet { return "No internet connection" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Where each model lives on disk.
enum ModelStorage {
    static func folders(for id: String) -> [URL] {
        switch id {
        case "parakeet-v2": [FluidHelpers.parakeetFolder(.v2)]
        case "parakeet-v3": [FluidHelpers.parakeetFolder(.v3)]
        case "parakeet-ultra": [FluidHelpers.parakeetFolder(.ultra)]
        case "parakeet-unified": [FluidHelpers.folder(.parakeetUnified)]
        case "cohere": [CohereEngine.directory]
        case "canary": [FluidHelpers.folder(.canary1bV2)]
        case "whisper-large-v3-turbo": [WhisperEngine.folder(for: WhisperEngine.turbo)]
        case "whisper-large-v3-turbo-q": [WhisperEngine.folder(for: WhisperEngine.turboCompact)]
        default: []
        }
    }

    /// How many compiled models a complete download contains.
    private static func requiredModelCount(_ id: String) -> Int {
        switch id {
        case "parakeet-v2", "parakeet-v3", "parakeet-ultra": 4 // preprocessor, encoder, decoder, joint
        case "parakeet-unified": 3
        case "cohere": 2 // encoder, decoder
        case "whisper-large-v3-turbo", "whisper-large-v3-turbo-q": 3 // mel, encoder, decoder
        default: 2
        }
    }

    /// True only when every compiled model is present and intact, so a half-finished
    /// download never counts as installed.
    static func isDownloaded(_ id: String) -> Bool {
        if id == "apple" { return true }
        let fm = FileManager.default
        let folders = folders(for: id)
        guard !folders.isEmpty else { return false }
        var complete = 0
        for folder in folders {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
            for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
                enumerator.skipDescendants()
                let hasSpec = fm.fileExists(atPath: url.appending(path: "coremldata.bin").path)
                let weights = url.appending(path: "weights/weight.bin")
                let weightsOK = !fm.fileExists(atPath: url.appending(path: "weights").path)
                    || ((try? fm.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? 0) > 0
                if hasSpec && weightsOK { complete += 1 }
            }
        }
        return complete >= requiredModelCount(id)
    }

    static func sizeOnDisk(_ id: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for folder in folders(for: id) {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    static func delete(_ id: String) {
        for folder in folders(for: id) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
}
