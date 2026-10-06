import SwiftUI

struct HistoryPage: View {
    @Environment(HistoryStore.self) private var history
    @ViewState private var query = ""
    @ViewState private var confirmClear = false

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.items }
        return history.items.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var grouped: [(String, [HistoryItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            let label: String
            if calendar.isDateInToday(day) { label = "Today" }
            else if calendar.isDateInYesterday(day) { label = "Yesterday" }
            else { label = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return (label, groups[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                PageHeader(title: "History", subtitle: "\(history.items.count) dictations, kept on this Mac.")
                if !history.items.isEmpty {
                    Button("Clear…", role: .destructive) { confirmClear = true }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary.opacity(0.8)))

            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing yet" : "No matches",
                    systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Your dictations will appear here." : "Try a different word.")
                )
                .padding(.top, 40)
            } else {
                ForEach(grouped, id: \.0) { label, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                HistoryRow(item: item)
                                if item.id != items.last?.id { Divider().opacity(0.5) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quinary.opacity(0.6)))
                    }
                }
            }
        }
        .confirmationDialog("Delete all history and recordings?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

struct HistoryRow: View {
    var item: HistoryItem
    var compact = false

    @Environment(HistoryStore.self) private var history
    @Environment(ModelManager.self) private var models
    @Environment(DictationController.self) private var dictation
    @ViewState private var hovering = false
    @ViewState private var expanded = false
    @ViewState private var copied = false
    @ViewState private var rerunning: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(.system(size: 13))
                    .lineLimit(expanded ? nil : (compact ? 2 : 3))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if expanded, item.rawText != item.text {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Heard").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(item.rawText).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 6) {
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                    if let app = item.appName { dot; Text(app) }
                    dot
                    Text(ModelCatalog.info(item.modelID).name)
                    dot
                    Text("\(item.audioSeconds.durationText) audio · \(String(format: "%.2fs", item.processingSeconds))")
                    if let rerunning {
                        dot
                        ProgressView().controlSize(.mini)
                        Text("Re-running with \(ModelCatalog.info(rerunning).name)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 2) {
                iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    TextInserter.copy(item.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if !compact {
                    Menu {
                        if item.hasAudio {
                            Section("Re-transcribe with") {
                                ForEach(ModelCatalog.all.filter { ModelStorage.isDownloaded($0.id) }) { model in
                                    Button(model.name) { rerun(with: model.id) }
                                }
                            }
                        }
                        Button(expanded ? "Collapse" : "Show original") { expanded.toggle() }
                        Divider()
                        Button("Delete", role: .destructive) { history.delete([item.id]) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 26, height: 26)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { expanded.toggle() }
        .animation(.smooth(duration: 0.15), value: hovering)
    }

    private var dot: some View { Text("·") }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func rerun(with modelID: String) {
        guard let audio = history.loadAudio(for: item) else { return }
        rerunning = modelID
        Task {
            defer { rerunning = nil }
            do {
                let engine = try await models.temporaryEngine(for: modelID)
                let output = try await dictation.transcribe(audio, focus: nil, modelID: modelID, engine: engine)
                if modelID != models.activeModelID { await engine.unload() }
                var updated = item
                updated.text = output.text
                updated.rawText = output.raw
                updated.modelID = modelID
                updated.processingSeconds = output.elapsed
                history.update(updated)
            } catch {
                NSLog("Cadence: re-transcribe failed: \(error.localizedDescription)")
            }
        }
    }
}
