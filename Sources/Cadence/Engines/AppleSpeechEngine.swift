import AVFoundation
import Speech

/// macOS's own on-device dictation model, via SpeechAnalyzer.
actor AppleSpeechEngine: TranscriptionEngine {
    private var locale: Locale?

    func prepare(progress: @escaping PrepareProgress) async throws {
        var resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale = resolved else { throw EngineError.unavailable("Apple dictation doesn't support your language") }

        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted, "Downloading from Apple")
            }
            try await request.downloadAndInstall()
            observation.invalidate()
        }
        self.locale = locale
        progress(1, "Ready")
    }

    func transcribe(_ samples: [Float], context: TranscriptionContext) async throws -> String {
        guard let locale else { throw EngineError.notLoaded }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !context.vocabulary.isEmpty {
            let analysisContext = AnalysisContext()
            analysisContext.contextualStrings[.general] = context.vocabulary
            try? await analyzer.setContext(analysisContext)
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let buffer = Self.buffer(samples, as: format) else { throw EngineError.unavailable("Couldn't prepare audio") }

        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    func unload() async {}

    private static func buffer(_ samples: [Float], as target: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        guard let target, target != source, let converter = AVAudioConverter(from: source, to: target) else { return input }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}
