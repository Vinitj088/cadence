import AppKit
import SwiftUI

/// A borderless, non-activating panel: it floats over everything (including full-screen apps)
/// without ever taking focus from the app the user is dictating into.
final class OverlayPanel: NSPanel {
    static let size = NSSize(width: 460, height: 230)

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none

        let host = FirstMouseHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the overlay's buttons and drag respond to the first click without activating the app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    /// Called when the user drops the pill on a new snap point.
    var onAnchorChanged: ((OverlayAnchor) -> Void)?

    private lazy var panel = OverlayPanel(model: model)
    private var hideWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private var dragOffset: NSPoint?
    private var transcribingSince: Date?
    private var pendingResult: DispatchWorkItem?

    /// Gap between the pill and the edge of the usable screen area.
    private let margin: CGFloat = 10
    /// Half the widest pill, so edge anchors keep every state fully on screen.
    private let maxHalfWidth: CGFloat = 135

    init() {
        model.onDragChanged = { [weak self] in self?.dragChanged() }
        model.onDragEnded = { [weak self] in self?.dragEnded() }
    }

    /// Puts the resting dash on screen (or removes it), and keeps it there between dictations.
    func setIdleVisible(_ visible: Bool) {
        model.showsIdle = visible
        if visible {
            ensureOnScreen()
        } else if model.phase == .hidden {
            hide()
        }
    }

    func show(_ phase: OverlayModel.Phase) {
        pendingResult?.cancel()
        pendingResult = nil
        if phase == .transcribing, model.phase != .transcribing { transcribingSince = Date() }
        hideWork?.cancel()
        ensureOnScreen()
        model.isHoveringIdle = false
        model.phase = phase
    }

    /// Shows a final state briefly, then folds back. If the racing pass is still running,
    /// the result waits for it to finish so the sweep is never cut off mid-run.
    func flash(_ phase: OverlayModel.Phase, for seconds: Double) {
        if model.phase == .transcribing, let since = transcribingSince {
            let remaining = PillBars.racingDuration - Date().timeIntervalSince(since)
            if remaining > 0.02 {
                let work = DispatchWorkItem { [weak self] in self?.flash(phase, for: seconds) }
                pendingResult = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
                return
            }
        }
        show(phase)
        hide(after: seconds)
    }

    /// Folds back into the resting dash, or removes the panel if the dash is turned off.
    func hide(after delay: Double = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.isDragging else { return }
            self.model.phase = .hidden
            self.model.reset()
            guard !self.model.showsIdle else { return }
            // Let the exit animation play before removing the window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.model.phase == .hidden, !self.model.showsIdle else { return }
                self.panel.orderOut(nil)
                self.panel.ignoresMouseEvents = true
                self.stopHoverTracking()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ensureOnScreen() {
        guard !panel.isVisible else { return }
        panel.setFrame(frame(for: model.anchor, on: preferredScreen()), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        startHoverTracking()
        logPlacement()
    }

    // MARK: - Snap points

    /// Panel frame for an anchor. The pill hugs the anchored edge inside the panel
    /// (see `OverlayView.edgeInset`), so it grows away from that edge.
    private func frame(for anchor: OverlayAnchor, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = OverlayPanel.size
        let centerX: CGFloat = switch anchor.column {
        case -1: visible.minX + margin + maxHalfWidth
        case 1: visible.maxX - margin - maxHalfWidth
        default: visible.midX
        }
        let originY: CGFloat = switch anchor.row {
        case -1: visible.minY + margin - OverlayView.edgeInset
        case 1: visible.maxY - margin + OverlayView.edgeInset - size.height
        default: visible.midY - size.height / 2
        }
        return NSRect(x: centerX - size.width / 2, y: originY, width: size.width, height: size.height)
    }

    /// Where the pill's centre rests for `anchor`, used to find the nearest snap point.
    private func restingCenter(for anchor: OverlayAnchor, on screen: NSScreen) -> NSPoint {
        let f = frame(for: anchor, on: screen)
        let y: CGFloat = switch anchor.row {
        case -1: f.minY + OverlayView.edgeInset + 20
        case 1: f.maxY - OverlayView.edgeInset - 20
        default: f.midY
        }
        return NSPoint(x: f.midX, y: y)
    }

    /// The screen with the menu bar: the dash stays put rather than chasing the mouse.
    private func preferredScreen() -> NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    // MARK: - Dragging

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            hideWork?.cancel()
            dragOffset = NSPoint(x: mouse.x - panel.frame.origin.x, y: mouse.y - panel.frame.origin.y)
            model.isDragging = true
            panel.ignoresMouseEvents = false
        }
        guard let offset = dragOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y))
    }

    private func dragEnded() {
        dragOffset = nil
        model.isDragging = false
        let pill = pillScreenRect()
        let center = NSPoint(x: pill.midX, y: pill.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? preferredScreen()

        let nearest = OverlayAnchor.allCases.min { a, b in
            distance(restingCenter(for: a, on: screen), center) < distance(restingCenter(for: b, on: screen), center)
        } ?? .bottom
        model.anchor = nearest
        onAnchorChanged?(nearest)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
            panel.animator().setFrame(frame(for: nearest, on: screen), display: true)
        }

        // A take that finished while the pill was held folds back once it lands.
        switch model.phase {
        case .inserted: hide(after: 0.5)
        case .copied, .message: hide(after: 1.2)
        default: break
        }
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Click-through

    /// The pill's frame in screen coordinates (the view reports it in top-left window space).
    private func pillScreenRect() -> NSRect {
        let r = model.pillFrame
        return NSRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The panel is much larger than the pill. Only the pill itself catches the mouse;
    /// everywhere else, clicks pass through to the app underneath.
    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func updateMousePassThrough() {
        guard !model.isDragging else { return }
        // The resting dash is tiny, so give it a more generous hit area.
        let slop: CGFloat = model.phase == .hidden ? 8 : 3
        let over = panel.isVisible && pillScreenRect().insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if !over, model.isHoveringIdle { model.isHoveringIdle = false }
    }

    private func logPlacement() {
        let screens = NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            logger.notice("""
            overlay: frame=\(NSStringFromRect(self.panel.frame), privacy: .public) \
            screen=\(self.panel.screen?.localizedName ?? "none", privacy: .public) \
            occlusionVisible=\(self.panel.occlusionState.contains(.visible), privacy: .public) \
            onActiveSpace=\(self.panel.isOnActiveSpace, privacy: .public) \
            screens=[\(screens.joined(separator: "; "), privacy: .public)]
            """)
        }
    }
}
