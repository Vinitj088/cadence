import SwiftUI

struct ModelsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                title: "Models",
                subtitle: "Every model runs on your Mac's Neural Engine. Free, offline, and private."
            )

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(ModelCatalog.all) { model in
                    ModelCard(model: model)
                }
            }

            Text("Accuracy and speed figures are averages over eight English test sets, published by Superwhisper from runs on an M4. Your voice, mic and vocabulary matter more. Use the test below to see how each model does for you.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VoiceTestCard()
        }
        .onAppear { models.refreshDiskState() }
    }
}

private struct ModelCard: View {
    var model: ModelInfo
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models
    @ViewState private var hovering = false
    @ViewState private var confirmDelete = false

    private var isActive: Bool { prefs.activeModelID == model.id }
    private var status: ModelManager.Status { models.status(of: model.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(model.name).font(.system(size: 14, weight: .semibold))
                        if let badge = model.badge { Badge(text: badge) }
                    }
                    Text("\(model.family.displayName) · \(model.languages)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.brand)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            Text(model.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 9) {
                MetricBar(label: "Accuracy", value: model.publishedWER.map(accuracyScore), caption: model.publishedWER.map { String(format: "%.1f%% WER", $0) } ?? "Not benchmarked")
                MetricBar(label: "Speed", value: model.publishedSpeed.map(speedScore), caption: model.publishedSpeed.map { String(format: "%.0f× real time", $0) } ?? "Not benchmarked")
            }

            Spacer(minLength: 0)

            HStack {
                Text(sizeText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                actions
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 238, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quinary.opacity(isActive ? 0.9 : 0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isActive ? Color.brand.opacity(0.55) : .primary.opacity(hovering ? 0.12 : 0.06), lineWidth: isActive ? 1.2 : 0.5)
                }
        }
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: isActive)
        .animation(.smooth(duration: 0.15), value: hovering)
        .confirmationDialog("Remove \(model.name)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { models.delete(model.id) }
        } message: {
            Text("You can download it again any time.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .downloading(let p, let label), .loading(let p, let label):
            HStack(spacing: 8) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                ProgressRing(progress: p).frame(width: 18, height: 18)
                Button {
                    models.cancel(model.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                Button("Retry") { use() }.controlSize(.small)
            }
        case .notDownloaded:
            HStack(spacing: 8) {
                Button("Download") { models.download(model.id) }.controlSize(.small)
                Button("Use") { use() }.buttonStyle(PrimaryButtonStyle()).controlSize(.small)
            }
        case .downloaded, .ready:
            HStack(spacing: 8) {
                if !isActive, model.family != .apple {
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .help("Remove from this Mac")
                }
                if isActive {
                    Text(status == .ready ? "In use" : "Loading…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.brand)
                } else {
                    Button("Use") { use() }.buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                }
            }
        }
    }

    private func use() {
        prefs.activeModelID = model.id
        models.activate(model.id)
    }

    private var sizeText: String {
        if model.family == .apple { return "Built in" }
        if status == .downloaded || status == .ready {
            let bytes = ModelStorage.sizeOnDisk(model.id)
            if bytes > 0 { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " on disk" }
        }
        return model.sizeMB >= 1000 ? String(format: "%.1f GB", Double(model.sizeMB) / 1000) : "\(model.sizeMB) MB"
    }

    /// 7% WER → full bar, 13% → a fifth.
    private func accuracyScore(_ wer: Double) -> Double {
        min(1, max(0.08, 1 - (wer - 7) / 7.5))
    }

    /// Log scale so 9× and 133× are both visible.
    private func speedScore(_ x: Double) -> Double {
        min(1, max(0.06, log(x) / log(150)))
    }
}

// MARK: - Test on your voice

private struct VoiceTestCard: View {
    @Environment(ModelManager.self) private var models
    @Environment(DictationController.self) private var dictation

    @ViewState private var passage = "Every morning I walk along the river before work. Yesterday the fog was so thick that I could barely see the bridge, but I could hear the gulls and the slow rumble of the early trains. By the time I reached the café, the sun had burned through and the whole city looked freshly washed."
    @ViewState private var recorder = AudioRecorder()
    @ViewState private var recording = false
    @ViewState private var running = false
    @ViewState private var results: [Result] = []
    @ViewState private var meter = LevelMeter()

    struct Result: Identifiable {
        var id: String
        var text: String
        var wer: Double
        var seconds: Double
    }

    var body: some View {
        Card(title: "Test on your voice", subtitle: "Read the passage aloud once. Every downloaded model transcribes the same recording, scored against the text.") {
            TextEditor(text: $passage)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .frame(height: 74)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.7)))

            HStack(spacing: 12) {
                Button {
                    recording ? stopAndRun() : startRecording()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                        Text(recording ? "Stop and compare" : "Record passage")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(running)

                if recording {
                    LiveWaveform(meter: meter, barCount: 18, color: .primary)
                        .frame(width: 90, height: 18)
                }
                if running {
                    ProgressView().controlSize(.small)
                    Text("Transcribing with each model…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        HStack(alignment: .top, spacing: 12) {
                            Text(index == 0 ? "🏆" : "\(index + 1)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ModelCatalog.info(result.id).name).font(.system(size: 12.5, weight: .semibold))
                                Text(result.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(String(format: "%.1f%% errors", result.wer * 100))
                                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(index == 0 ? Color.brand : .primary)
                                Text(String(format: "%.2fs", result.seconds))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 9)
                        if index < results.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    private func startRecording() {
        guard Permissions.microphone == .granted else {
            Permissions.requestMicrophone()
            return
        }
        meter.reset()
        recorder.meter = meter
        do {
            try recorder.start(device: AudioDevices.resolve(uid: Preferences.shared.microphoneUID, preferBuiltIn: Preferences.shared.preferBuiltInMic))
            recording = true
            results = []
        } catch {
            recording = false
        }
    }

    private func stopAndRun() {
        let audio = recorder.stop()
        recording = false
        guard audio.count > 16_000 else { return }
        running = true
        let reference = passage
        Task {
            defer { running = false }
            for model in ModelCatalog.all where ModelStorage.isDownloaded(model.id) {
                do {
                    let engine = try await models.temporaryEngine(for: model.id)
                    let start = Date()
                    let raw = try await engine.transcribe(audio, context: TranscriptionContext())
                    let elapsed = Date().timeIntervalSince(start)
                    if model.id != models.activeModelID { await engine.unload() }
                    let result = Result(id: model.id, text: raw, wer: WordErrorRate.compute(reference: reference, hypothesis: raw), seconds: elapsed)
                    withAnimation(.smooth) {
                        results.append(result)
                        results.sort { $0.wer == $1.wer ? $0.seconds < $1.seconds : $0.wer < $1.wer }
                    }
                } catch {
                    continue
                }
            }
        }
    }
}
