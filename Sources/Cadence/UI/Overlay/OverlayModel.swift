import Foundation
import Observation

@Observable
@MainActor
final class OverlayModel {
    enum Phase: Equatable {
        case hidden
        case preparing(String)
        case listening(handsFree: Bool)
        case transcribing
        case polishing
        case inserted
        case copied
        case message(String, isError: Bool)
    }

    var phase: Phase = .hidden
    var startedAt: Date?
    var livePreview: String = ""
    var anchor: OverlayAnchor = .bottom
    var isDragging = false
    /// Between dictations, rest as a thin dash instead of disappearing.
    var showsIdle = true
    var isHoveringIdle = false

    /// Fed by the recorder; read by the waveform every frame. Not observed.
    @ObservationIgnored let meter = LevelMeter()
    /// The pill's frame in the panel (top-left origin), so the panel knows which pixels are clickable.
    @ObservationIgnored var pillFrame: CGRect = .zero

    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored var onDragChanged: (() -> Void)?
    @ObservationIgnored var onDragEnded: (() -> Void)?
    /// Clicking the resting dash starts hands-free dictation.
    @ObservationIgnored var onActivate: (() -> Void)?

    func reset() {
        meter.reset()
        livePreview = ""
    }
}
