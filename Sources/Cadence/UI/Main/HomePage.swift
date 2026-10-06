import SwiftUI

struct HomePage: View {
    @Binding var page: Page
    @Environment(Preferences.self) private var prefs
    @Environment(HistoryStore.self) private var history
    @Environment(ModelManager.self) private var models
    @ViewState private var scratch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: greeting, subtitle: "Speak anywhere on your Mac. Everything stays on this computer.")

            HowToCard(trigger: prefs.triggerKey)

            HStack(spacing: 12) {
                StatTile(value: history.totalWords.formatted(), label: "words dictated", symbol: "text.word.spacing")
                StatTile(value: history.wordsPerMinute > 0 ? "\(history.wordsPerMinute)" : "—", label: "words per minute", symbol: "speedometer")
                StatTile(value: history.minutesSaved < 1 ? "—" : (history.minutesSaved * 60).durationText, label: "saved vs typing", symbol: "hourglass")
                StatTile(value: "\(history.streakDays)", label: history.streakDays == 1 ? "day streak" : "day streak", symbol: "flame")
            }
            .animation(.smooth, value: history.totalWords)

            Card(title: "Try it here", subtitle: "Click in the box, hold \(prefs.triggerKey.glyph) and say something.") {
                TextEditor(text: $scratch)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.7)))
            }

            if !history.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("See all") { page = .history }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                    VStack(spacing: 0) {
                        ForEach(history.items.prefix(5)) { item in
                            HistoryRow(item: item, compact: true)
                            if item.id != history.items.prefix(5).last?.id { Divider().opacity(0.5) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quinary.opacity(0.6)))
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init)
        return first.map { "\(part), \($0)" } ?? part
    }
}

/// Teaches the two gestures with a looping miniature of the real overlay.
private struct HowToCard: View {
    var trigger: TriggerKey

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Gesture(keys: trigger.glyph, title: "Hold to talk", detail: "Release to insert the text where your cursor is.")
                Gesture(keys: "\(trigger.glyph) tap", title: "Tap for hands-free", detail: "Talk as long as you like; tap again to finish.")
                Gesture(keys: "esc", title: "Cancel", detail: "Throws the take away.")
            }
            Spacer(minLength: 0)
            DemoPill()
                .frame(width: 230, height: 120)
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.brand.opacity(0.16), Color.brand.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.brand.opacity(0.18), lineWidth: 0.5)
                }
        }
    }

    private struct Gesture: View {
        var keys: String
        var title: String
        var detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                KeyCap(label: keys, size: 12)
                    .frame(minWidth: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A self-running preview of the overlay: listening → racing → done.
private struct DemoPill: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.4)
            let stage = cycle < 3 ? 0 : cycle < 4.5 ? 1 : 2

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                VStack {
                    Spacer()
                    Group {
                        switch stage {
                        case 0: LiveWaveform(meter: LevelMeter(), simulate: true).frame(width: 112, height: 22)
                        case 1: RacingWave().frame(width: 112, height: 22)
                        default:
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Capsule().fill(Color(white: 0.06)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: stage)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}
