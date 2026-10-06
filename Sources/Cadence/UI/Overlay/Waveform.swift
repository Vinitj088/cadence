import SwiftUI

/// Hands loudness from the audio thread to the renderer without touching SwiftUI state.
///
/// The recorder enqueues one value per 10 ms of audio. The renderer drains the queue at
/// real-time speed, so the meter moves smoothly even when the system delivers audio in
/// larger, bursty buffers.
final class LevelMeter: @unchecked Sendable {
    private var queue: [Float] = []
    private var lock = os_unfair_lock()
    private var lastValue: Float = 0

    static let chunkDuration: Double = 0.01

    func push(_ levels: [Float]) {
        os_unfair_lock_lock(&lock)
        queue.append(contentsOf: levels)
        // If rendering stalls, keep only the most recent ~150 ms rather than lagging behind.
        if queue.count > 15 { queue.removeFirst(queue.count - 15) }
        os_unfair_lock_unlock(&lock)
    }

    /// Consumes the chunks that "played" during `dt` and returns their loudest value.
    func drain(dt: Double) -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !queue.isEmpty else {
            lastValue *= 0.9
            return lastValue
        }
        // Drain a little faster than real time when a backlog builds, to stay current.
        let base = max(1, Int((dt / Self.chunkDuration).rounded()))
        let count = min(queue.count, queue.count > 6 ? base + 1 : base)
        let value = queue.prefix(count).max() ?? 0
        queue.removeFirst(count)
        lastValue = value
        return value
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        queue.removeAll()
        lastValue = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Per-view animation state, mutated by the renderer each frame.
private final class WaveformState {
    var bars: [Double] = []
    var level: Double = 0
    var lastTime: Double = 0
}

/// A centre-weighted bar meter drawn every display frame.
///
/// Each bar chases its target with a fast attack (~25 ms) and a softer release (~110 ms),
/// independent of frame rate, so speech onsets register instantly and decay without flicker.
/// A slow per-bar ripple keeps the shape organic instead of a uniform block.
struct LiveWaveform: View {
    var meter: LevelMeter
    var barCount = 26
    var color: Color = .white
    var paused = false
    /// Drives the bars with synthetic speech instead of the meter (for previews).
    var simulate = false

    @ViewState private var state = WaveformState()

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Double) {
        if state.bars.count != barCount { state.bars = Array(repeating: 0, count: barCount) }
        let dt = state.lastTime == 0 ? 1 / 60 : min(0.05, max(0.001, now - state.lastTime))
        state.lastTime = now

        let raw = simulate
            ? max(0, 0.45 + 0.4 * sin(now * 3.3) * sin(now * 1.27 + 0.6) + 0.15 * sin(now * 11))
            : Double(meter.drain(dt: dt))
        state.level = approach(state.level, raw, dt: dt, attack: 0.018, release: 0.09)

        let spacing: CGFloat = size.width / CGFloat(barCount) * 0.42
        let barWidth = (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
        let minHeight = max(2.5, barWidth)

        for i in 0..<barCount {
            let x = Double(i) / Double(barCount - 1)
            // Bell envelope: the centre reacts most, the edges taper.
            let envelope = 0.3 + 0.7 * pow(sin(.pi * x), 1.5)
            // Slow, incommensurate sines per bar: organic motion that never visibly repeats.
            let ripple = 0.7 + 0.3 * sin(now * (4.1 + Double(i % 5) * 0.83) + Double(i) * 1.9)
            // At rest the bars breathe gently instead of freezing flat.
            let idle = 0.05 + 0.035 * (0.5 + 0.5 * sin(now * 1.9 - Double(i) * 0.45))
            let target = max(idle, state.level * envelope * ripple)
            state.bars[i] = approach(state.bars[i], target, dt: dt, attack: 0.025, release: 0.11)

            let value = state.bars[i]
            let height = minHeight + (size.height - minHeight) * CGFloat(min(1, value))
            let rect = CGRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(color.opacity(0.5 + 0.5 * min(1, value * 1.6)))
            )
        }
    }

    /// Frame-rate-independent exponential smoothing with separate rise and fall time constants.
    private func approach(_ current: Double, _ target: Double, dt: Double, attack: Double, release: Double) -> Double {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}

/// Shown while the model works: the bars settle into a row of dots and a bright comet races
/// across them exactly once, trailing light behind it. It launches hard and glides in, which
/// reads as speed. If the model is still busy afterwards, the row breathes quietly instead of
/// racing again. Drawn per display frame (120 Hz on ProMotion).
struct RacingWave: View {
    /// Length of the single pass. The overlay waits for it to finish before showing the result.
    static let duration = 0.62

    var color: Color = .white
    var barCount = 26

    @ViewState private var startedAt = Date.timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, t: timeline.date.timeIntervalSinceReferenceDate - startedAt)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let spacing = size.width / CGFloat(barCount) * 0.42
        let barWidth = (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
        let dot = max(2.5, barWidth)
        let tail = 0.55 // trail length as a fraction of the row

        // One pass: the head runs from just off the left edge to past the right, so the trail fully clears.
        let raw = min(1, t / Self.duration)
        let eased = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
        let head = -0.08 + eased * (1 + tail + 0.16)

        // Fade the comet in at the start so the hand-off from the live waveform is seamless.
        let intro = min(1, t / 0.12)

        if raw >= 1 {
            drawResting(in: &context, size: size, barWidth: barWidth, spacing: spacing, dot: dot, t: t - Self.duration)
            return
        }

        // A soft streak of light under the bars, brightest at the head.
        let headX = CGFloat(head) * size.width
        let streak = CGRect(x: headX - size.width * CGFloat(tail), y: size.height / 2 - 1, width: size.width * CGFloat(tail), height: 2)
        context.fill(
            Path(roundedRect: streak, cornerRadius: 1),
            with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.35 * intro)]),
                startPoint: CGPoint(x: streak.minX, y: 0),
                endPoint: CGPoint(x: streak.maxX, y: 0)
            )
        )

        for i in 0..<barCount {
            let x = Double(i) / Double(barCount - 1)
            let behind = head - x
            var intensity: Double
            if behind >= 0 {
                intensity = behind < tail ? pow(1 - behind / tail, 2.4) : 0
            } else {
                intensity = exp(behind * 38) // a faint glow just ahead of the head
            }
            intensity *= intro
            let envelope = 0.55 + 0.45 * sin(.pi * x)
            let height = dot + (size.height * 0.82 - dot) * CGFloat(intensity * envelope)
            let rect = CGRect(x: CGFloat(i) * (barWidth + spacing), y: (size.height - height) / 2, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(color.opacity(0.22 + 0.78 * intensity))
            )
        }
    }

    /// After the pass: a calm row of dots with a slow wave of brightness, until the result lands.
    private func drawResting(in context: inout GraphicsContext, size: CGSize, barWidth: CGFloat, spacing: CGFloat, dot: CGFloat, t: Double) {
        let fadeIn = min(1, t / 0.2)
        for i in 0..<barCount {
            let x = Double(i) / Double(barCount - 1)
            let wave = 0.5 + 0.5 * sin(t * 3.2 - x * 5)
            let rect = CGRect(x: CGFloat(i) * (barWidth + spacing), y: (size.height - dot) / 2, width: barWidth, height: dot)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.22 + 0.3 * wave * fadeIn)))
        }
    }
}

// MARK: - The pill's bars

/// One continuous bar row for the pill. Live speech and the racing pass are two behaviours of
/// the same bars: every bar eases from one to the other, so the hand-off is a morph, not a cut.
struct PillBars: View {
    enum Mode: Equatable { case live, racing }

    /// Length of the single racing pass. The overlay waits for it before showing the result.
    static let racingDuration = 0.62

    var meter: LevelMeter
    var mode: Mode
    var barCount = 26
    var color: Color = .white

    @ViewState private var state = PillBarsState()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Double) {
        if state.heights.count != barCount {
            state.heights = Array(repeating: 0, count: barCount)
            state.glow = Array(repeating: 0.5, count: barCount)
        }
        if state.mode != mode {
            state.mode = mode
            state.modeStart = now
        }
        let dt = state.lastTime == 0 ? 1 / 60 : min(0.05, max(0.001, now - state.lastTime))
        state.lastTime = now

        let spacing = size.width / CGFloat(barCount) * 0.42
        let barWidth = (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
        let dot = max(2.5, barWidth)
        let span = Double(size.height - dot)

        // Live loudness keeps updating (and decaying) in both modes so the morph has momentum.
        let raw = mode == .live ? Double(meter.drain(dt: dt)) : 0
        state.level = approach(state.level, raw, dt: dt, attack: 0.018, release: 0.09)

        let t = now - state.modeStart
        let tail = 0.55
        let progress = min(1, t / Self.racingDuration)
        let eased = progress < 0.5 ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2
        let head = -0.08 + eased * (1 + tail + 0.16)

        for i in 0..<barCount {
            let x = Double(i) / Double(barCount - 1)
            var targetHeight: Double
            var targetGlow: Double

            switch mode {
            case .live:
                let envelope = 0.3 + 0.7 * pow(sin(.pi * x), 1.5)
                let ripple = 0.7 + 0.3 * sin(now * (4.1 + Double(i % 5) * 0.83) + Double(i) * 1.9)
                let idle = 0.05 + 0.035 * (0.5 + 0.5 * sin(now * 1.9 - Double(i) * 0.45))
                targetHeight = max(idle, state.level * envelope * ripple)
                targetGlow = 0.5 + 0.5 * min(1, targetHeight * 1.6)
            case .racing:
                if progress < 1 {
                    let behind = head - x
                    let intensity = behind >= 0 ? (behind < tail ? pow(1 - behind / tail, 2.4) : 0) : exp(behind * 38)
                    let envelope = 0.55 + 0.45 * sin(.pi * x)
                    targetHeight = 0.82 * intensity * envelope
                    targetGlow = 0.22 + 0.78 * intensity
                } else {
                    // Still working after the pass: a calm row of dots with a slow wave of light.
                    let wave = 0.5 + 0.5 * sin((t - Self.racingDuration) * 3.2 - x * 5)
                    targetHeight = 0
                    targetGlow = 0.22 + 0.3 * wave
                }
            }

            // Racing moves fast, so bars follow it tightly; live speech gets the softer release.
            let (attack, release) = mode == .racing ? (0.012, 0.035) : (0.025, 0.11)
            state.heights[i] = approach(state.heights[i], targetHeight, dt: dt, attack: attack, release: release)
            state.glow[i] = approach(state.glow[i], targetGlow, dt: dt, attack: 0.02, release: 0.06)

            let height = dot + CGFloat(span * min(1, state.heights[i]))
            let rect = CGRect(x: CGFloat(i) * (barWidth + spacing), y: (size.height - height) / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(state.glow[i])))
        }

        // The racing pass trails a soft streak of light along the centre line.
        if mode == .racing, progress < 1 {
            let intro = min(1, t / 0.12)
            let headX = CGFloat(head) * size.width
            let streak = CGRect(x: headX - size.width * CGFloat(tail), y: size.height / 2 - 1, width: size.width * CGFloat(tail), height: 2)
            context.fill(
                Path(roundedRect: streak, cornerRadius: 1),
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(0.35 * intro)]),
                    startPoint: CGPoint(x: streak.minX, y: 0),
                    endPoint: CGPoint(x: streak.maxX, y: 0)
                )
            )
        }
    }

    private func approach(_ current: Double, _ target: Double, dt: Double, attack: Double, release: Double) -> Double {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}

private final class PillBarsState {
    var heights: [Double] = []
    var glow: [Double] = []
    var level: Double = 0
    var lastTime: Double = 0
    var mode: PillBars.Mode = .live
    var modeStart: Double = 0
}

/// A checkmark that strokes itself in.
struct DrawnCheckmark: View {
    @ViewState private var progress: CGFloat = 0

    var body: some View {
        CheckShape()
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .frame(width: 15, height: 11)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3).delay(0.06)) { progress = 1 }
            }
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}
