import SwiftUI

struct DictionaryPage: View {
    @Environment(Preferences.self) private var prefs
    @ViewState private var newTerm = ""
    @ViewState private var newSpoken = ""
    @ViewState private var newWritten = ""

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Dictionary", subtitle: "Teach Cadence your names, jargon and spellings.")

            Card(
                title: "Vocabulary",
                subtitle: "Words the models should listen for. Parakeet, Whisper and Apple use these while decoding; every model gets their spelling and capitalization fixed afterwards."
            ) {
                HStack(spacing: 8) {
                    TextField("Add a word or name, like Kubernetes or Figma", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if prefs.vocabulary.isEmpty {
                    Text("No words yet.").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(prefs.vocabulary, id: \.self) { term in
                            HStack(spacing: 5) {
                                Text(term).font(.system(size: 12.5, weight: .medium))
                                Button {
                                    withAnimation(.smooth(duration: 0.2)) { prefs.vocabulary.removeAll { $0 == term } }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.brand.opacity(0.12)))
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }

            Card(
                title: "Replacements",
                subtitle: "Whenever Cadence hears the phrase on the left, it writes the text on the right. Good for addresses, sign-offs and recurring misspellings."
            ) {
                HStack(spacing: 8) {
                    TextField("When I say…", text: $newSpoken)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("Write…", text: $newWritten)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(newSpoken.trimmingCharacters(in: .whitespaces).isEmpty || newWritten.isEmpty)
                }

                if !prefs.replacements.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(prefs.replacements) { rule in
                            HStack {
                                Text(rule.spoken).font(.system(size: 12.5)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(rule.written).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Button {
                                    prefs.replacements.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            if rule.id != prefs.replacements.last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
            }

            Card(title: "Voice commands", subtitle: "Say these while dictating.") {
                VStack(alignment: .leading, spacing: 8) {
                    command("“new line”", "Starts a new line")
                    command("“new paragraph”", "Leaves a blank line")
                    command("“twenty five dollars”", "Written as $25 (Parakeet models)")
                }
            }
        }
    }

    private func command(_ phrase: String, _ effect: String) -> some View {
        HStack {
            Text(phrase).font(.system(size: 12.5, weight: .medium)).frame(width: 190, alignment: .leading)
            Text(effect).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private func addTerm() {
        let terms = newTerm.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        withAnimation(.smooth(duration: 0.2)) {
            for term in terms where !prefs.vocabulary.contains(term) { prefs.vocabulary.append(term) }
        }
        newTerm = ""
    }

    private func addReplacement() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !newWritten.isEmpty else { return }
        prefs.replacements.append(Replacement(spoken: spoken, written: newWritten))
        newSpoken = ""
        newWritten = ""
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
