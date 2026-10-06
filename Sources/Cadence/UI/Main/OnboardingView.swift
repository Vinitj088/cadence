import SwiftUI

struct OnboardingView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models
    @Environment(HistoryStore.self) private var history
    @Environment(DictationController.self) private var dictation

    @ViewState private var step = 0
    @ViewState private var micGranted = Permissions.microphone == .granted
    @ViewState private var axGranted = Permissions.accessibility
    @ViewState private var practice = ""
    @ViewState private var startCount = 0

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                case 2: accessibility
                case 3: chooseModel
                default: tryIt
                }
            }
            .frame(maxWidth: 520)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            Spacer(minLength: 20)

            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.brand : Color.primary.opacity(0.15))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RadialGradient(colors: [Color.brand.opacity(0.13), .clear], center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
        .task(id: step) { await pollPermissions() }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            LogoMark().frame(width: 72, height: 72)
                .shadow(color: Color.brand.opacity(0.35), radius: 24, y: 10)
            VStack(spacing: 10) {
                Text("Cadence").font(.system(size: 40, weight: .semibold)).tracking(-0.8)
                Text("Speak, and your words appear wherever you're typing.\nPrivate, instant, and entirely on your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Get started") { step = 1 }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
    }

    private var microphone: some View {
        StepLayout(
            symbol: "mic.fill",
            title: "Let Cadence hear you",
            detail: "Audio is processed on this Mac and never sent anywhere. The mic is only on while you hold the key.",
            done: micGranted
        ) {
            if micGranted {
                Button("Continue") { step = 2 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Allow microphone") {
                    Permissions.requestMicrophone { granted in
                        micGranted = granted
                        if granted { step = 2 }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var accessibility: some View {
        StepLayout(
            symbol: "keyboard.fill",
            title: "Let Cadence type for you",
            detail: "Accessibility access lets Cadence notice your dictation key and paste text into other apps. Turn on Cadence in the list that opens.",
            done: axGranted
        ) {
            if axGranted {
                Button("Continue") { step = 3 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 10) {
                    Button("Open Accessibility settings") { Permissions.requestAccessibility() }
                        .buttonStyle(PrimaryButtonStyle())
                    Text("This page moves on by itself once it's on.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var chooseModel: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Pick a voice model").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                Text("It downloads once and then works offline. You can switch any time.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                modelOption("parakeet-v2", detail: "Instant results, excellent English accuracy. 480 MB.")
                modelOption("cohere", detail: "The most accurate. Takes a moment longer. 2.1 GB.")
                modelOption("whisper-large-v3-turbo", detail: "OpenAI Whisper. Strong with your vocabulary. 1.6 GB.")
            }
            Button("Continue") {
                models.activate(prefs.activeModelID)
                startCount = history.items.count
                step = 4
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func modelOption(_ id: String, detail: String) -> some View {
        let model = ModelCatalog.info(id)
        let selected = prefs.activeModelID == id
        return Button {
            prefs.activeModelID = id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Color.brand : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(model.name).font(.system(size: 14, weight: .semibold))
                        if let badge = model.badge { Badge(text: badge) }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quinary.opacity(selected ? 1 : 0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? Color.brand.opacity(0.6) : .clear, lineWidth: 1.2)
                    }
            }
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: selected)
    }

    private var tryIt: some View {
        let status = models.status(of: prefs.activeModelID)
        let succeeded = history.items.count > startCount
        return VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(succeeded ? "That's it." : "Give it a try").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                HStack(spacing: 8) {
                    Text("Click the box, then hold")
                    KeyCap(label: prefs.triggerKey.glyph, size: 12)
                    Text("and speak. Let go when you're done.")
                }
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            }

            TextEditor(text: $practice)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.opacity(0.8)))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(succeeded ? Color.brand.opacity(0.6) : .primary.opacity(0.1), lineWidth: succeeded ? 1.2 : 0.5)
                }

            Group {
                switch status {
                case .downloading(let p, let label), .loading(let p, let label):
                    HStack(spacing: 10) {
                        ProgressRing(progress: p).frame(width: 16, height: 16)
                        Text("\(ModelCatalog.info(prefs.activeModelID).name): \(label) \(Int(p * 100))%")
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .ready:
                    Label("\(ModelCatalog.info(prefs.activeModelID).name) is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Button(succeeded ? "Start using Cadence" : "Skip for now") {
                prefs.hasOnboarded = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(succeeded ? .defaultAction : .cancelAction)
        }
    }

    /// The system doesn't notify when Accessibility is granted, so check while that step is visible.
    private func pollPermissions() async {
        while !Task.isCancelled {
            micGranted = Permissions.microphone == .granted
            let trusted = Permissions.accessibility
            if trusted && !axGranted {
                axGranted = true
                dictation.start() // re-register key monitors now that they're permitted
                if step == 2 { step = 3 }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}

private struct StepLayout<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String
    var done: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: done ? "checkmark" : symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(spacing: 8) {
                Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 4)
        }
    }
}
