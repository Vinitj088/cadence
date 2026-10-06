// Re-transcribes WAV files with a chosen engine, sequentially, for accuracy debugging.
// Usage: CadenceBench <parakeet-v2|parakeet-v3|parakeet-ultra|cohere|whisper> file.wav...
import AVFoundation
import FluidAudio
import WhisperKit

func load(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func profile(_ s: [Float]) -> String {
    let window = 8000 // 0.5 s
    return stride(from: 0, to: s.count, by: window).map { start in
        let chunk = s[start..<min(start + window, s.count)]
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let db = 20 * log10(max(rms, 1e-7))
        return db > -35 ? "█" : db > -45 ? "▄" : db > -55 ? "▁" : "·"
    }.joined()
}

let args = CommandLine.arguments.dropFirst()
guard let engine = args.first else { fatalError("engine?") }
let files = Array(args.dropFirst())

var transcribe: ([Float]) async throws -> String

switch engine {
case "parakeet-v2", "parakeet-v3", "parakeet-ultra":
    let version: AsrModelVersion = engine == "parakeet-v2" ? .v2 : engine == "parakeet-v3" ? .v3 : .ultra
    let models = try await AsrModels.downloadAndLoad(version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    transcribe = { samples in
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
case "cohere":
    try await ModelHub.download(.cohereTranscribeCoreml, to: MLModelConfigurationUtils.defaultModelsDirectory()) { p in
        FileHandle.standardError.write("\rcohere \(Int(p.fractionCompleted * 100))%".data(using: .utf8)!)
    }
    let dir = MLModelConfigurationUtils.defaultModelsDirectory().appending(path: Repo.cohereTranscribeCoreml.folderName)
    let models = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
    let pipeline = CoherePipeline()
    transcribe = { try await pipeline.transcribeLong(audio: $0, models: models, language: .english, maxNewTokens: 256).text }
case "whisper":
    let base = URL.applicationSupportDirectory.appending(path: "Cadence/Models/whisper")
    let variant = "openai_whisper-large-v3-v20240930_turbo"
    let folder = try await WhisperKit.download(variant: variant, downloadBase: base) { p in
        FileHandle.standardError.write("\rwhisper \(Int(p.fractionCompleted * 100))%".data(using: .utf8)!)
    }
    let kit = try await WhisperKit(WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
    transcribe = { samples in
        let options = DecodingOptions(language: "en", temperatureFallbackCount: 3, skipSpecialTokens: true, chunkingStrategy: .vad)
        return try await kit.transcribe(audioArray: samples, decodeOptions: options).map(\.text).joined(separator: " ")
    }
default:
    fatalError("unknown engine \(engine)")
}

for path in files {
    let samples = try load(path)
    let start = Date()
    let text = try await transcribe(samples)
    let name = URL(fileURLWithPath: path).lastPathComponent.prefix(8)
    print("\(name) \(String(format: "%4.1fs", Double(samples.count) / 16000)) \(String(format: "%.2fs", Date().timeIntervalSince(start)))  \(profile(samples))")
    print("    → \(text)")
}
