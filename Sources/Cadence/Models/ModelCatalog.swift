import Foundation

enum ModelFamily: String, Codable {
    case parakeet, whisper, cohere, canary, apple

    var displayName: String {
        switch self {
        case .parakeet: "NVIDIA Parakeet"
        case .whisper: "OpenAI Whisper"
        case .cohere: "Cohere Transcribe"
        case .canary: "NVIDIA Canary"
        case .apple: "Apple"
        }
    }
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let family: ModelFamily
    let summary: String
    /// Approximate download size.
    let sizeMB: Int
    /// Mean word error rate across eight English test sets, measured by Superwhisper
    /// on an M4 inside a shipping app. Nil where no comparable number has been published.
    let publishedWER: Double?
    /// Multiple of real time on the same benchmark.
    let publishedSpeed: Double?
    let languages: String
    let englishOnly: Bool
    /// Fast enough to re-run on every second of audio for the live preview.
    let supportsLivePreview: Bool
    /// Accepts the user's vocabulary as a decoding hint (not just post-correction).
    let usesVocabularyNatively: Bool
    var badge: String? = nil
}

enum ModelCatalog {
    static let defaultModelID = "parakeet-v2"

    static let all: [ModelInfo] = [
        ModelInfo(
            id: "parakeet-v2", name: "Parakeet v2", family: .parakeet,
            summary: "Near-instant English dictation with excellent recall. The best everyday default.",
            sizeMB: 480, publishedWER: 10.4, publishedSpeed: 133, languages: "English", englishOnly: true,
            supportsLivePreview: true, usesVocabularyNatively: true, badge: "Recommended"
        ),
        ModelInfo(
            id: "cohere", name: "Cohere Transcribe", family: .cohere,
            summary: "The most accurate model here — about a fifth fewer errors than Whisper Turbo. Slower to return.",
            sizeMB: 2_100, publishedWER: 8.4, publishedSpeed: 24, languages: "14 languages", englishOnly: false,
            supportsLivePreview: false, usesVocabularyNatively: false, badge: "Most accurate"
        ),
        ModelInfo(
            id: "parakeet-ultra", name: "Parakeet Ultra", family: .parakeet,
            summary: "Parakeet v3 post-trained for accuracy, at the same speed.",
            sizeMB: 600, publishedWER: nil, publishedSpeed: nil, languages: "25 European languages", englishOnly: false,
            supportsLivePreview: true, usesVocabularyNatively: true, badge: "New"
        ),
        ModelInfo(
            id: "parakeet-v3", name: "Parakeet v3", family: .parakeet,
            summary: "Multilingual Parakeet. Pick it if you dictate in more than English.",
            sizeMB: 480, publishedWER: 10.7, publishedSpeed: 118, languages: "25 European languages", englishOnly: false,
            supportsLivePreview: true, usesVocabularyNatively: true
        ),
        ModelInfo(
            id: "parakeet-unified", name: "Parakeet Unified", family: .parakeet,
            summary: "English model that writes numbers, dates and currency in their written form.",
            sizeMB: 650, publishedWER: nil, publishedSpeed: nil, languages: "English", englishOnly: true,
            supportsLivePreview: true, usesVocabularyNatively: true
        ),
        ModelInfo(
            id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", family: .whisper,
            summary: "OpenAI's flagship, distilled for speed. Takes your vocabulary and recent text as a prompt.",
            sizeMB: 1_600, publishedWER: 10.9, publishedSpeed: 9.4, languages: "99 languages", englishOnly: false,
            supportsLivePreview: false, usesVocabularyNatively: true
        ),
        ModelInfo(
            id: "whisper-large-v3-turbo-q", name: "Whisper Large v3 Turbo (compact)", family: .whisper,
            summary: "The same Turbo model quantized to a third of the size, with a small accuracy cost.",
            sizeMB: 632, publishedWER: nil, publishedSpeed: nil, languages: "99 languages", englishOnly: false,
            supportsLivePreview: false, usesVocabularyNatively: true
        ),
        ModelInfo(
            id: "canary", name: "Canary 1B v2", family: .canary,
            summary: "NVIDIA's larger encoder-decoder model with punctuation and casing.",
            sizeMB: 1_000, publishedWER: nil, publishedSpeed: nil, languages: "25 European languages", englishOnly: false,
            supportsLivePreview: false, usesVocabularyNatively: false
        ),
        ModelInfo(
            id: "apple", name: "Apple Dictation", family: .apple,
            summary: "Built into macOS. Nothing to download from here, and it understands your vocabulary.",
            sizeMB: 0, publishedWER: nil, publishedSpeed: nil, languages: "Your system language", englishOnly: false,
            supportsLivePreview: false, usesVocabularyNatively: true
        ),
    ]

    static func info(_ id: String) -> ModelInfo {
        all.first { $0.id == id } ?? all[0]
    }
}
