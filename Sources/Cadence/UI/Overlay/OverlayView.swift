import SwiftUI

/// The overlay: one black capsule that rests as a thin dash and morphs, Dynamic Island style,
/// into the full pill while dictating. It grows away from the screen edge it's parked on.
struct OverlayView: View {
    var model: OverlayModel

    /// Space between the pill and the panel edge it's anchored to.
    static let edgeInset: CGFloat = 12

    private let morph = Animation.spring(response: 0.42, dampingFraction: 0.76)

    private var isIdle: Bool { model.phase == .hidden }
    private var isVisible: Bool { !isIdle || model.showsIdle }

    var body: some View {
        let isTop = model.anchor.isTop
        let alignment: Alignment = switch model.anchor.row {
        case 1: .top
        case -1: .bottom
        default: .center
        }

        ZStack {
            if isVisible {
                pill
                    .overlay(alignment: isTop ? .bottom : .top) {
                        preview
                            .alignmentGuide(isTop ? .bottom : .top) { d in
                                isTop ? d[.top] - 10 : d[.bottom] + 10
                            }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(alignment == .bottom ? .bottom : .top, alignment == .center ? 0 : Self.edgeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(morph, value: model.phase)
        .animation(morph, value: model.isHoveringIdle)
        .animation(morph, value: model.showsIdle)
        .animation(.smooth(duration: 0.25), value: model.livePreview)
    }

    // MARK: - Pill

    private var pill: some View {
        ZStack {
            content
                .id(contentID)
                .transition(
                    .asymmetric(
                        // Content fades in once the capsule has started to open, and leaves quickly.
                        insertion: .opacity.combined(with: .scale(scale: 0.85)).animation(.easeOut(duration: 0.22).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    )
                )
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .background {
            Capsule().fill(Color(white: isIdle ? 0.1 : 0.06).opacity(isIdle ? 0.92 : 1))
        }
        .overlay {
            // A hairline so the pill keeps its edge on dark wallpapers.
            Capsule().strokeBorder(.white.opacity(isIdle ? 0.22 : 0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(isIdle ? 0.18 : (model.isDragging ? 0.4 : 0.28)), radius: isIdle ? 4 : (model.isDragging ? 22 : 14), y: isIdle ? 1 : (model.isDragging ? 10 : 5))
        .scaleEffect(model.isDragging ? 1.04 : 1)
        .contentShape(Capsule().inset(by: -6))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.pillFrame = $0 }
        .onHover { hovering in if isIdle { model.isHoveringIdle = hovering } }
        .onTapGesture { if isIdle { model.onActivate?() } }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in model.onDragChanged?() }
                .onEnded { _ in model.onDragEnded?() }
        )
        .pointerStyle(model.isDragging ? .grabActive : (isIdle ? .link : .grabIdle))
        .help(isIdle ? "Click to dictate, or drag to move" : "")
    }

    private var height: CGFloat {
        if isIdle { return model.isHoveringIdle ? 9 : 6 }
        return 40
    }

    private var horizontalPadding: CGFloat {
        switch model.phase {
        case .hidden: 0
        case .listening(true): 5
        case .listening(false), .transcribing: 18
        case .inserted: 20
        default: 15
        }
    }

    /// Changes whenever the inside of the pill should cross-fade.
    private var contentID: String {
        switch model.phase {
        case .hidden: "idle"
        case .preparing: "preparing"
        // Listening and processing are the same bars changing behaviour: never cross-faded.
        case .listening, .transcribing: "bars"
        case .polishing: "polishing"
        case .inserted: "inserted"
        case .copied: "copied"
        case .message(let text, _): "message-\(text)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .hidden:
            Color.clear.frame(width: model.isHoveringIdle ? 58 : 40, height: 1)

        case .preparing(let label):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).tint(.white)
                Text(label)
            }
            .pillText()

        case .listening, .transcribing:
            let handsFree = model.phase == .listening(handsFree: true)
            HStack(spacing: 10) {
                if handsFree {
                    OverlayButton(symbol: "xmark", prominent: false) { model.onCancel?() }
                        .help("Cancel (Esc)")
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
                if model.editingSelection, model.phase != .transcribing {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .help("Say what to do with the selected text")
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                PillBars(meter: model.meter, mode: model.phase == .transcribing ? .racing : .live)
                    .frame(width: handsFree ? 112 : 128, height: 24)
                if handsFree {
                    if let start = model.startedAt {
                        ElapsedTime(start: start)
                            .transition(.opacity)
                    }
                    OverlayButton(symbol: "stop.fill", prominent: true) { model.onStop?() }
                        .help("Finish")
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            }

        case .polishing:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.workingLabel)
            }
            .pillText()

        case .inserted:
            DrawnCheckmark()

        case .copied:
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill")
                Text("Copied — ⌘V to paste")
            }
            .pillText()

        case .message(let text, let isError):
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? Color(red: 1, green: 0.75, blue: 0.3) : .white.opacity(0.85))
                Text(text)
                    .lineLimit(1)
            }
            .pillText()
        }
    }

    // MARK: - Live preview

    @ViewBuilder
    private var preview: some View {
        if case .listening = model.phase, !model.livePreview.isEmpty, !model.isDragging {
            Text(model.livePreview.suffix(160))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2, reservesSpace: false)
                .truncationMode(.head)
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    func pillText() -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
    }
}

// MARK: - Pieces

struct ElapsedTime: View {
    var start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 34)
        }
    }
}

struct OverlayButton: View {
    var symbol: String
    var prominent: Bool
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 10 : 11, weight: .bold))
                .foregroundStyle(prominent ? Color.black : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.2 : 0.1))
                }
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
