import AVFoundation
import AudioToolbox
import CoreAudio

enum RecorderError: LocalizedError {
    case noInput
    case converter

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone available"
        case .converter: "Couldn't read from the microphone"
        }
    }
}

/// Captures the microphone and accumulates 16 kHz mono Float32, the format every engine wants.
/// A fresh AVAudioEngine per session keeps device switches (AirPods in/out) from leaving a stale format.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0

    /// Receives a 0…1 loudness value for every 10 ms of audio, for the live waveform.
    var meter: LevelMeter?

    var isRecording: Bool { engine?.isRunning ?? false }

    func start(device: AudioDeviceID?) throws {
        stopEngine()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(Int(Self.sampleRate) * 60)
            peak = 0
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Only retarget the input unit when it must differ from the system default: switching it
        // forces a reconfiguration, and tapping before that settles fails with a format mismatch.
        if let device, device != AudioDevices.defaultInput(), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // The hardware side of the input bus reflects the device actually selected.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw RecorderError.noInput }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw RecorderError.converter }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capture and returns everything recorded since `start`.
    @discardableResult
    func stop() -> [Float] {
        stopEngine()
        return lock.withLock { samples }
    }

    /// Number of 16 kHz samples captured so far.
    var sampleCount: Int { lock.withLock { samples.count } }

    /// The audio so far, without stopping — used for live preview.
    func snapshot() -> [Float] {
        lock.withLock { samples }
    }

    /// Loudest level seen this session; near-zero means the mic delivered silence.
    var peakLevel: Float { lock.withLock { peak } }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: channel, count: count)

        // Loudness per 10 ms slice so the meter gets a steady, fine-grained stream.
        let slice = Int(Self.sampleRate * LevelMeter.chunkDuration)
        var levels: [Float] = []
        levels.reserveCapacity(count / slice + 1)
        var start = 0
        var level: Float = 0
        while start < count {
            let end = min(start + slice, count)
            var sum: Float = 0
            for i in start..<end { sum += chunk[i] * chunk[i] }
            let rms = sqrt(sum / Float(end - start))
            // Map roughly -58 dB…-12 dB onto 0…1 with a gentle curve; speech sits in the upper half.
            let db = 20 * log10(max(rms, 1e-7))
            let linear = min(max((db + 58) / 46, 0), 1)
            let shaped = Float(pow(Double(linear), 1.35))
            levels.append(shaped)
            level = max(level, shaped)
            start = end
        }
        meter?.push(levels)

        lock.withLock {
            samples.append(contentsOf: chunk)
            peak = max(peak, level)
        }
    }
}
