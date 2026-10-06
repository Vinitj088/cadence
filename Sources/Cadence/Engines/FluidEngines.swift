import FluidAudio
import Foundation

private func label(for progress: DownloadProgress) -> String {
    switch progress.phase {
    case .listing: "Preparing download"
    case .downloading(let done, let total): total > 0 ? "Downloading \(done)/\(total)" : "Downloading"
    case .compiling: "Optimizing for this Mac"
    }
}

// MARK: - Parakeet (TDT)

actor ParakeetEngine: TranscriptionEngine {
    private let version: AsrModelVersion
    private var manager: AsrManager?
    private let vocabulary = VocabularyBooster()

    init(version: AsrModelVersion) {
        self.version = version
    }

    func prepare(progress: @escaping PrepareProgress) async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: version) { p in
            progress(p.fractionCompleted, label(for: p))
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        progress(1, "Warming up")
        // The first inference compiles Neural Engine kernels; pay that cost now, not on the first dictation.
        _ = try? await run([Float](repeating: 0, count: 16_000), language: nil)
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        let language: Language? = version == .v2 ? nil : Language(rawValue: context.language)
        let result = try await run(samples, language: language)
        return await vocabulary.rescore(result, samples: samples, terms: context.vocabulary)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    private func run(_ samples: [Float], language: Language?) async throws -> ASRResult {
        guard let manager else { throw EngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state, language: language)
    }
}

/// Parakeet's custom-vocabulary support: a small CTC model spots the user's terms in the
/// audio and rescores the transcript toward them. Loaded lazily the first time there's a vocabulary.
actor VocabularyBooster {
    private var ctc: CtcModels?
    private var session: VocabularyBoostingSession?
    private var sessionTerms: [String] = []
    private var loading = false

    func rescore(_ result: ASRResult, samples: [Float], terms: [String]) async -> String {
        let usable = terms.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return result.text }
        guard let session = await session(for: usable) else { return result.text }
        let output = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        return output?.text ?? result.text
    }

    private func session(for terms: [String]) async -> VocabularyBoostingSession? {
        if terms == sessionTerms, let session { return session }
        guard let ctc = await models() else { return nil }
        let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        session = try? await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
        sessionTerms = terms
        return session
    }

    private func models() async -> CtcModels? {
        if let ctc { return ctc }
        guard !loading else { return nil }
        loading = true
        defer { loading = false }
        ctc = try? await CtcModels.downloadAndLoad(variant: .ctc110m)
        return ctc
    }
}

// MARK: - Parakeet Unified

actor ParakeetUnifiedEngine: TranscriptionEngine {
    private var manager: UnifiedAsrManager?
    private var ctc: CtcModels?
    private var configuredTerms: [String] = []

    func prepare(progress: @escaping PrepareProgress) async throws {
        if manager != nil { return }
        let manager = UnifiedAsrManager()
        try await manager.loadModels { p in progress(p.fractionCompleted, label(for: p)) }
        self.manager = manager
        progress(1, "Warming up")
        _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000))
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        guard let manager else { throw EngineError.notLoaded }
        let terms = context.vocabulary.filter { $0.count >= 3 }
        if !terms.isEmpty, terms != configuredTerms {
            if ctc == nil { ctc = try? await CtcModels.downloadAndLoad(variant: .ctc110m) }
            if let ctc {
                try? await manager.configureVocabularyBoosting(
                    vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
                    ctcModels: ctc
                )
                configuredTerms = terms
            }
        }
        return try await manager.transcribe(samples)
    }

    func unload() async {
        manager = nil
    }
}

// MARK: - Cohere Transcribe

actor CohereEngine: TranscriptionEngine {
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    static var directory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory().appending(path: Repo.cohereTranscribeCoreml.folderName, directoryHint: .isDirectory)
    }

    func prepare(progress: @escaping PrepareProgress) async throws {
        if models != nil { return }
        try await ModelHub.download(.cohereTranscribeCoreml, to: MLModelConfigurationUtils.defaultModelsDirectory()) { p in
            progress(p.fractionCompleted * 0.95, label(for: p))
        }
        progress(0.96, "Loading model")
        let dir = Self.directory
        models = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
        progress(1, "Warming up")
        _ = try? await transcribe([Float](repeating: 0, count: 16_000), context: TranscriptionContext())
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        guard let models else { throw EngineError.notLoaded }
        let language = CohereAsrConfig.Language(rawValue: context.language) ?? .english
        // 35 s of fast speech can exceed the default 108-token budget, which would cut sentences off.
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: language, maxNewTokens: 256)
        return result.text
    }

    func unload() async {
        models = nil
    }
}

// MARK: - Canary

actor CanaryEngine: TranscriptionEngine {
    private var manager: CanaryManager?

    func prepare(progress: @escaping PrepareProgress) async throws {
        if manager != nil { return }
        manager = try await CanaryManager.load(precision: .int8) { p in progress(p.fractionCompleted, label(for: p)) }
        progress(1, "Warming up")
        _ = try? await manager?.transcribe(audio: [Float](repeating: 0, count: 16_000))
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        guard let manager else { throw EngineError.notLoaded }
        return try await manager.transcribe(audio: samples)
    }

    func unload() async {
        manager = nil
    }
}

// MARK: - Shared helpers

enum FluidHelpers {
    /// Spoken-form numbers, dates and currency to written form: "twenty five dollars" → "$25".
    static func normalize(_ text: String) -> String {
        TextNormalizer.shared.normalizeSentence(text)
    }

    static let modelsRoot = MLModelConfigurationUtils.defaultModelsDirectory()

    static func folder(_ repo: Repo) -> URL {
        modelsRoot.appending(path: repo.folderName, directoryHint: .isDirectory)
    }

    static func parakeetFolder(_ version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }
}

/// Trims leading/trailing silence with Silero VAD and reports whether anyone spoke at all.
/// Whisper in particular invents text ("Thank you.") when handed silence.
actor SpeechGate {
    private var vad: VadManager?
    private var failed = false

    func prepare() async {
        guard vad == nil, !failed else { return }
        do { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.6)) } catch { failed = true }
    }

    /// Returns the audio trimmed to the span with speech (plus padding), an empty array if
    /// there was no speech, or the input unchanged if the VAD isn't available.
    func trim(_ samples: [Float]) async -> [Float] {
        guard let vad, samples.count > 8_000 else { return samples }
        guard let segments = try? await vad.segmentSpeech(samples), let first = segments.first, let last = segments.last else {
            return (try? await vad.segmentSpeech(samples)) == nil ? samples : []
        }
        let pad = 4_800 // 0.3 s, so word onsets and trailing consonants survive
        let start = max(0, first.startSample(sampleRate: 16_000) - pad)
        let end = min(samples.count, last.endSample(sampleRate: 16_000) + pad)
        guard end > start else { return samples }
        return Array(samples[start..<end])
    }
}
