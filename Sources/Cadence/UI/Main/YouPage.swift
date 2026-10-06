import SwiftUI

/// Everything Cadence has learned about the user, in one place, all of it editable or removable.
struct YouPage: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(VoiceFit.self) private var voiceFit
    @Environment(AppStyleStore.self) private var styles
    @Environment(LearningStore.self) private var learning
    @Environment(HistoryStore.self) private var history
    @Environment(ModelManager.self) private var models
    @Environment(Preferences.self) private var prefs
    @Environment(DictationController.self) private var dictation

    @ViewState private var draft = ""
    @ViewState private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "You", subtitle: "What Cadence has learned about how you work. It never leaves this Mac.")

            Card(title: "Profile", subtitle: "Written by Apple's on-device model from your dictations. It helps every model spell your world right.") {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.7)))
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }.controlSize(.small)
                        Button("Save") {
                            profile.setText(draft)
                            editing = false
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .controlSize(.small)
                    }
                } else if profile.text.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.text.rectangle").foregroundStyle(.secondary)
                        Text(history.items.count < 15
                             ? "Builds itself after about 15 dictations (\(history.items.count) so far)."
                             : "Ready to build from your \(history.items.count) dictations.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profile.text.split(separator: "\n").map(String.init), id: \.self) { line in
                            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(parts.first ?? "").font(.system(size: 12, weight: .semibold)).frame(width: 64, alignment: .leading)
                                Text(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
                                    .font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !editing {
                    HStack(spacing: 10) {
                        if let updated = profile.updated {
                            Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if profile.isUpdating { ProgressView().controlSize(.small) }
                        Button("Edit") {
                            draft = profile.text
                            editing = true
                        }
                        .controlSize(.small)
                        Button(profile.text.isEmpty ? "Build now" : "Refresh") {
                            profile.refresh(history: history, learning: learning)
                        }
                        .controlSize(.small)
                        .disabled(profile.isUpdating || history.items.isEmpty || !Polisher.isAvailable)
                        if !profile.text.isEmpty {
                            Button("Clear", role: .destructive) { profile.clear() }.controlSize(.small)
                        }
                    }
                }
            }

            VoiceFitCard()

            Card(title: "Writing habits by app", subtitle: "Learned from small edits you make, like deleting the full stop Cadence added in a chat app.") {
                let habits = styles.learnedHabits
                if habits.isEmpty {
                    Text("None yet. Defaults: commands stay bare in terminals, no full stop on chat messages, lists in prompts and email.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(habits, id: \.key) { habit in
                            HStack {
                                Text(Self.placeName(habit.key)).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Text([habit.dropsPeriod ? "no final full stop" : nil, habit.lowercase ? "lowercase start" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Button { styles.forget(habit.key) } label: { Image(systemName: "minus.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Forget")
                            }
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    static func placeName(_ key: String) -> String {
        if key.hasPrefix("web:") { return key.dropFirst(4).capitalized + " (web)" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return key
    }
}

/// How each model performs on the user's own voice, and a switch suggestion when it's clear.
struct VoiceFitCard: View {
    @Environment(VoiceFit.self) private var voiceFit
    @Environment(HistoryStore.self) private var history
    @Environment(ModelManager.self) private var models
    @Environment(Preferences.self) private var prefs
    @Environment(DictationController.self) private var dictation

    var body: some View {
        let samples = voiceFit.samples(in: history).count
        Card(title: "Your voice", subtitle: "Every dictation you correct becomes a test. When your Mac is idle, each installed model is scored on those recordings.") {
            if let rec = voiceFit.recommendation(active: prefs.activeModelID) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Color.brand)
                    Text("\(ModelCatalog.info(rec.id).name) made \(Int(rec.improvement * 100))% fewer mistakes on your voice than \(ModelCatalog.info(prefs.activeModelID).name).")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("Switch") {
                        prefs.activeModelID = rec.id
                        models.activate(rec.id)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.brand.opacity(0.07)))
            }
            let scored = voiceFit.scores.sorted { $0.value.errorRate < $1.value.errorRate }
            if scored.isEmpty {
                Text(samples < VoiceFit.minimumTakes
                     ? "Needs \(VoiceFit.minimumTakes) corrected dictations (\(samples) so far). Fix words Cadence gets wrong and this fills in."
                     : "Ready to test \(samples) corrected dictations.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(scored, id: \.key) { id, score in
                        MetricBar(
                            label: ModelCatalog.info(id).name + (id == prefs.activeModelID ? "  ·  in use" : ""),
                            value: max(0.04, 1 - score.errorRate * 4),
                            caption: String(format: "%.1f%% errors · %d takes", score.errorRate * 100, score.takes)
                        )
                    }
                }
            }
            HStack {
                if voiceFit.isRunning {
                    ProgressView().controlSize(.small)
                    Text(voiceFit.progress).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test now") {
                    voiceFit.run(history: history, models: models) { id, audio in
                        let engine = try await models.temporaryEngine(for: id)
                        let text = try await engine.transcribe(audio, context: TranscriptionContext())
                        if id != models.activeModelID, engine !== models.companion { await engine.unload() }
                        return text
                    }
                }
                .controlSize(.small)
                .disabled(voiceFit.isRunning || samples == 0)
            }
        }
    }
}
