import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, models, dictionary, you, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .models: "Models"
        case .dictionary: "Dictionary"
        case .you: "You"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "waveform"
        case .history: "clock.arrow.circlepath"
        case .models: "cpu"
        case .dictionary: "character.book.closed"
        case .you: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if prefs.hasOnboarded {
                MainView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: prefs.hasOnboarded)
        .onAppear {
            OpenWindowBridge.open = { id in openWindow(id: id) }
        }
    }
}

struct MainView: View {
    @ViewState private var page: Page = .home

    var body: some View {
        NavigationSplitView {
            Sidebar(page: $page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 240)
        } detail: {
            ScrollView {
                Group {
                    switch page {
                    case .home: HomePage(page: $page)
                    case .history: HistoryPage()
                    case .models: ModelsPage()
                    case .dictionary: DictionaryPage()
                    case .you: YouPage()
                    case .settings: SettingsPage()
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .id(page)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.2), value: page)
        .onReceive(NotificationCenter.default.publisher(for: .cadenceNavigate)) { note in
            if let target = note.object as? Page { page = target }
        }
    }
}

extension Notification.Name {
    static let cadenceNavigate = Notification.Name("cadenceNavigate")
}

private struct Sidebar: View {
    @Binding var page: Page
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LogoMark()
                    .frame(width: 22, height: 22)
                Text("Cadence")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 16)

            List(selection: Binding(get: { page }, set: { if let p = $0 { page = p } })) {
                ForEach(Page.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)

            Spacer()

            ActiveModelFooter()
                .padding(12)
        }
    }
}

private struct ActiveModelFooter: View {
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models

    var body: some View {
        let model = ModelCatalog.info(prefs.activeModelID)
        let status = models.status(of: model.id)
        Button {
            NotificationCenter.default.post(name: .cadenceNavigate, object: Page.models)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    switch status {
                    case .downloading(let p, _), .loading(let p, _):
                        ProgressRing(progress: p, lineWidth: 2).frame(width: 14, height: 14)
                    case .ready:
                        Circle().fill(.green).frame(width: 7, height: 7)
                    case .failed:
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    default:
                        Circle().fill(.secondary).frame(width: 7, height: 7)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(statusText(status)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private func statusText(_ status: ModelManager.Status) -> String {
        switch status {
        case .ready: "Ready · hold \(prefs.triggerKey.glyph) to talk"
        case .downloading(let p, _): "Downloading \(Int(p * 100))%"
        case .loading: "Loading…"
        case .failed(let m): m
        case .downloaded: "Not loaded"
        case .notDownloaded: "Not downloaded"
        }
    }
}

/// The brand mark: voice bars resolving into a text cursor, off-white on matte black.
/// Mirrors scripts/make-icon.swift.
struct LogoMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                    .fill(Color(red: 0.086, green: 0.094, blue: 0.106))
                    .overlay {
                        RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    }
                Canvas { context, size in
                    let w = size.width * 0.72
                    let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - w) / 2)
                    let bar = w * 0.072, gap = w * 0.058
                    let heights: [CGFloat] = [0.20, 0.38, 0.54, 0.30]
                    let caretGap = w * 0.11, stem = w * 0.06, cap = w * 0.2, thick = w * 0.055, caretH = w * 0.62
                    let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap + caretGap + cap
                    let midY = origin.y + w / 2
                    var x = origin.x + w / 2 - total / 2
                    let ink = GraphicsContext.Shading.color(Color(red: 0.953, green: 0.949, blue: 0.925))
                    for h in heights {
                        let height = w * h
                        context.fill(Path(roundedRect: CGRect(x: x, y: midY - height / 2, width: bar, height: height), cornerRadius: bar / 2), with: ink)
                        x += bar + gap
                    }
                    x += caretGap - gap
                    let top = midY - caretH / 2
                    context.fill(Path(roundedRect: CGRect(x: x + cap / 2 - stem / 2, y: top, width: stem, height: caretH), cornerRadius: stem / 2), with: ink)
                    context.fill(Path(roundedRect: CGRect(x: x, y: top, width: cap, height: thick), cornerRadius: thick / 2), with: ink)
                    context.fill(Path(roundedRect: CGRect(x: x, y: top + caretH - thick, width: cap, height: thick), cornerRadius: thick / 2), with: ink)
                }
            }
        }
    }
}
