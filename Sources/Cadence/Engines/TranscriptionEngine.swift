import Foundation

/// Everything an engine may use to transcribe more accurately.
struct TranscriptionContext: Sendable {
    /// ISO code, e.g. "en".
    var language = "en"
    /// Names, jargon and spellings the user cares about.
    var vocabulary: [String] = []
    /// Text just before the caret. Whisper uses it as a prompt for style and spelling.
    var precedingText: String?
}

typealias PrepareProgress = @Sendable (_ fraction: Double, _ label: String) -> Void

/// A local speech-to-text model. Every implementation is an actor so that model state
/// never crosses threads unsynchronised.
protocol TranscriptionEngine: Actor {
    /// Downloads (if needed), loads and warms up the model.
    func prepare(progress: @escaping PrepareProgress) async throws
    /// Audio is 16 kHz mono Float32.
    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String
    func unload() async
}

enum EngineError: LocalizedError {
    case notLoaded
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The model isn't loaded yet"
        case .unavailable(let reason): reason
        }
    }
}

enum EngineFactory {
    static func make(for model: ModelInfo) -> any TranscriptionEngine {
        switch model.id {
        case "parakeet-v2": ParakeetEngine(version: .v2)
        case "parakeet-v3": ParakeetEngine(version: .v3)
        case "parakeet-ultra": ParakeetEngine(version: .ultra)
        case "parakeet-unified": ParakeetUnifiedEngine()
        case "cohere": CohereEngine()
        case "canary": CanaryEngine()
        case "whisper-large-v3-turbo": WhisperEngine(variant: WhisperEngine.turbo)
        case "whisper-large-v3-turbo-q": WhisperEngine(variant: WhisperEngine.turboCompact)
        case "apple": AppleSpeechEngine()
        default: ParakeetEngine(version: .v2)
        }
    }
}
