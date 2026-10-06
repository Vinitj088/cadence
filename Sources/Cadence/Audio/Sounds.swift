import AppKit

/// Short, soft cues synthesized at launch: a rising two-note chime to start, falling to stop.
/// Generated rather than bundled so they're tuned to sit quietly under whatever is playing.
@MainActor
enum Sounds {
    enum Cue { case start, stop, cancel }

    private static let cache: [Cue: NSSound] = {
        var sounds: [Cue: NSSound] = [:]
        sounds[.start] = make([(784, 0.0), (1175, 0.055)], volume: 0.22)
        sounds[.stop] = make([(1175, 0.0), (784, 0.055)], volume: 0.2)
        sounds[.cancel] = make([(523, 0.0)], volume: 0.16)
        return sounds
    }()

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled, let sound = cache[cue] else { return }
        sound.stop()
        sound.play()
    }

    /// Each note is (frequency Hz, start offset s): a sine with a soft attack and exponential decay.
    private static func make(_ notes: [(Double, Double)], volume: Float) -> NSSound? {
        let rate = 44_100.0
        let length = 0.22
        var samples = [Float](repeating: 0, count: Int(rate * length))
        for (frequency, offset) in notes {
            let start = Int(offset * rate)
            for i in start..<samples.count {
                let t = Double(i - start) / rate
                let attack = min(1, t / 0.004)
                let envelope = attack * exp(-t * 26)
                // A quiet octave partial adds a little glassiness.
                let tone = sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t)
                samples[i] += Float(tone * envelope * 0.5)
            }
        }
        guard let data = wav(samples, rate: Int(rate)), let sound = NSSound(data: data) else { return nil }
        sound.volume = volume
        return sound
    }

    private static func wav(_ samples: [Float], rate: Int) -> Data? {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
