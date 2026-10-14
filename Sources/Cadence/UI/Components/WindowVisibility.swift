import AppKit
import SwiftUI

/// Whether the hosting window is actually on screen.
///
/// Closing the main window only orders it out: its SwiftUI tree stays alive, and every
/// `TimelineView(.animation)` inside keeps drawing at the display's refresh rate with nobody
/// watching. Views that animate on their own read this to stop drawing while the window is
/// closed, minimised, hidden or fully covered.
private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isWindowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

extension View {
    /// Publishes the hosting window's occlusion state as `isWindowVisible` to this view's subtree.
    func tracksWindowVisibility() -> some View {
        modifier(TracksWindowVisibility())
    }
}

private struct TracksWindowVisibility: ViewModifier {
    @ViewState private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.isWindowVisible, visible)
            .background(WindowObserver { visible = $0 })
    }
}

private struct WindowObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
