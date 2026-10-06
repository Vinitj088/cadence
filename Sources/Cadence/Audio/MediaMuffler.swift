import CoreAudio
import Foundation

/// While dictating, makes everything else playing on the Mac sound like it's coming through a
/// wall: muffled, bass-heavy and quieter. Like music from a club heard in its bathroom.
///
/// Nothing is paused. A Core Audio process tap captures every other app's output and mutes the
/// originals; an aggregate device plays the tapped audio back through a low-pass filter. On
/// release the filter sweeps open again and the tap is removed, so the audio returns untouched.
final class MediaMuffler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cadence.muffler")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var teardown: DispatchWorkItem?
    private let dsp = MuffleDSP()

    /// Seconds for the filter to sweep back open before the tap is removed.
    private let releaseDuration = 0.5

    func engage() {
        queue.async { [self] in
            teardown?.cancel()
            teardown = nil
            dsp.target = 1
            guard procID == nil else { return }
            do {
                try start()
            } catch {
                logger.error("muffler: \(error.localizedDescription, privacy: .public)")
                stop()
            }
        }
    }

    func release() {
        queue.async { [self] in
            dsp.target = 0
            guard procID != nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            teardown = work
            queue.asyncAfter(deadline: .now() + releaseDuration, execute: work)
        }
    }

    // MARK: - Setup

    private func start() throws {
        guard let outputUID = Self.defaultOutputUID() else { throw MufflerError("no output device") }

        // Tap everything except Cadence itself, so its own chimes stay clean.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Cadence muffle"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw MufflerError("unexpected tap format")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cadence Muffle",
            kAudioAggregateDeviceUIDKey: "cadence.muffle.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        dsp.prepare(sampleRate: format.mSampleRate)
        let dsp = self.dsp
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            dsp.process(input: input, output: output)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
        logger.notice("muffler engaged on \(outputUID, privacy: .public)")
    }

    private func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw MufflerError("\(step) failed (\(status))") }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

private struct MufflerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The real-time part. Runs on the audio thread: no allocation, no locks.
final class MuffleDSP: @unchecked Sendable {
    /// 0 = untouched, 1 = fully muffled. Written by the controller, read by the audio thread.
    var target: Double = 0

    private static let maxChannels = 8
    private var amount: Double = 0
    private var sampleRate: Double = 48_000
    // Two cascaded biquads per channel: x1, x2, y1, y2 for each stage.
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * 8)

    init() {
        state.initialize(repeating: 0, count: Self.maxChannels * 8)
    }

    deinit {
        state.deallocate()
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        amount = 0
        state.update(repeating: 0, count: Self.maxChannels * 8)
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let source = inputs.first, let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let inChannels = max(1, Int(source.mNumberChannels))
        let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)

        // Ease toward the target: closing in ~0.3 s, opening in ~0.45 s.
        let seconds = Double(frames) / sampleRate
        let tau = target > amount ? 0.1 : 0.15
        amount += (target - amount) * (1 - exp(-seconds / tau))

        // Sweep the cutoff in log space so the "door closing" sounds even, and drop the level.
        let shaped = amount * amount * (3 - 2 * amount)
        let cutoff = exp(log(18_000.0) + (log(480.0) - log(18_000.0)) * shaped)
        let gain = Float(1 - 0.5 * shaped)
        let (b0, b1, b2, a1, a2) = Self.lowPass(cutoff: min(cutoff, sampleRate * 0.45), q: 0.707, sampleRate: sampleRate)

        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = max(1, Int(buffer.mNumberChannels))
            let outFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels))
            for channel in 0..<min(outChannels, Self.maxChannels) {
                let inChannel = channel % inChannels
                let s = state + channel * 8
                for frame in 0..<outFrames {
                    var x = Double(sourceData[frame * inChannels + inChannel])
                    // Stage 1
                    var y = b0 * x + b1 * s[0] + b2 * s[1] - a1 * s[2] - a2 * s[3]
                    s[1] = s[0]; s[0] = x; s[3] = s[2]; s[2] = y
                    // Stage 2
                    x = y
                    y = b0 * x + b1 * s[4] + b2 * s[5] - a1 * s[6] - a2 * s[7]
                    s[5] = s[4]; s[4] = x; s[7] = s[6]; s[6] = y
                    data[frame * outChannels + channel] = Float(y) * gain
                }
            }
        }
    }

    /// RBJ cookbook low-pass, normalised.
    private static func lowPass(cutoff: Double, q: Double, sampleRate: Double) -> (Double, Double, Double, Double, Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = (1 - cosW) / 2 / a0
        return (b0, (1 - cosW) / a0, b0, -2 * cosW / a0, (1 - alpha) / a0)
    }
}
