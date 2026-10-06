import AppKit
import SwiftUI

extension Color {
    /// The single accent: matte black in light mode, soft white in dark mode.
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.09, alpha: 1)
    })
    /// Text and icons drawn on top of `brand`.
    static let onBrand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.07, alpha: 1) : .white
    })
}

/// A physical-looking key, used wherever we teach the shortcut.
struct KeyCap: View {
    var label: String
    var size: CGFloat = 13
    var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, size * 0.62)
            .frame(minWidth: size * 2.1, minHeight: size * 2.1)
            .background {
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(pressed ? 0.05 : 0.14), radius: 0, y: pressed ? 0.5 : 1.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .offset(y: pressed ? 1 : 0)
    }
}

/// A titled group of controls on a soft card.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quinary.opacity(0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quinary.opacity(0.6))
        }
    }
}

/// A labelled 0…1 bar for comparing models at a glance.
struct MetricBar: View {
    var label: String
    var value: Double?
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(caption).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    if let value {
                        Capsule()
                            .fill(Color.brand)
                            .frame(width: max(4, geo.size.width * value))
                    }
                }
            }
            .frame(height: 5)
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
        }
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .brand

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row in a settings card: label and explanation on the left, control on the right.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.onBrand)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.brand))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

extension Double {
    var durationText: String {
        if self < 60 { return String(format: "%.0fs", self) }
        let minutes = Int(self) / 60, seconds = Int(self) % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}
