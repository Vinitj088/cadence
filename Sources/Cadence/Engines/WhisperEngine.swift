import Foundation
import WhisperKit

actor WhisperEngine: TranscriptionEngine {
    static let turbo = "openai_whisper-large-v3-v20240930_turbo"
    static let turboCompact = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"

    static var downloadBase: URL {
        URL.applicationSupportDirectory.appending(path: "Cadence/Models/whisper", directoryHint: .isDirectory)
    }

    static func folder(for variant: String) -> URL {
        downloadBase.appending(path: "models/\(repo)/\(variant)", directoryHint: .isDirectory)
    }

    private let variant: String
    private var kit: WhisperKit?

    init(variant: String) {
        self.variant = variant
    }

    func prepare(progress: @escaping PrepareProgress) async throws {
        if kit != nil { return }
        let base = Self.downloadBase
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = try await WhisperKit.download(variant: variant, downloadBase: base, from: Self.repo) { p in
            progress(p.fractionCompleted * 0.8, "Downloading")
        }
        progress(0.82, "Optimizing for this Mac")
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: base,
            modelRepo: Self.repo,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
        progress(1, "Ready")
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        guard let kit else { throw EngineError.notLoaded }
        var options = DecodingOptions(
            task: .transcribe,
            language: context.language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        if let prompt = Self.prompt(for: context), let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    /// Whisper conditions on a "previous text" prompt: a glossary teaches it spellings,
    /// and the text before the caret teaches it the register and punctuation style.
    private static func prompt(for context: TranscriptionContext) -> String? {
        var parts: [String] = []
        if !context.vocabulary.isEmpty {
            parts.append("Glossary: " + context.vocabulary.prefix(40).joined(separator: ", ") + ".")
        }
        if let before = context.precedingText?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            parts.append(String(before.suffix(200)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
