import SwiftUI

struct EnveCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var theme = ThemeManager.shared
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(colors.cardStroke, lineWidth: 1)
            }
    }
}

struct SectionTitle: View {
    let title: String
    var systemImage: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.enveAccent)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StatusBadge: View {
    let text: String
    let health: Health

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Circle().fill(health.color).frame(width: 7, height: 7)
        }
        .labelStyle(BadgeLabelStyle())
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(health.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private struct BadgeLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color = .enveAccent
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.8: .enveAccent
        case ..<0.92: .yellow
        default: .red
        }
    }
}

struct RingGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    let title: String
    let valueText: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(UsageBar.tint(for: fraction).gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
                Text(valueText)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(10)
            }
            .frame(width: 88, height: 88)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(monospaced ? .body.monospaced() : .body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var health: Health?

    var body: some View {
        EnveCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.enveAccent)
                    Spacer()
                    if let health {
                        Image(systemName: health.systemImage)
                            .foregroundStyle(health.color)
                    }
                }
                .font(.subheadline)
                .accessibilityHidden(true)
                Text(value)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, health.map(\.accessibilityName)].compactMap { $0 }.joined(separator: ", "))
    }
}

struct PreviewBanner: View {
    var body: some View {
        Label("Sample Data Preview", systemImage: "eye")
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.enveAccent, in: Capsule())
            .accessibilityLabel("Preview mode. Everything shown is sample data, not a real server.")
    }
}
