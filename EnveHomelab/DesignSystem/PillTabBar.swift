import SwiftUI

struct PillTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let systemImage: (Tab) -> String
    var badge: (Tab) -> Int = { _ in 0 }

    @Namespace private var highlight
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: systemImage(tab))
                            .font(.system(size: iconSize, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if badge(tab) > 0 {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 5, y: -3)
                                }
                            }
                        Text(title(tab))
                            .font(.system(size: labelSize, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.black : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.enveAccent)
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(tab))
                .accessibilityValue(badge(tab) > 0 ? "\(badge(tab)) unread" : "")
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

private struct BottomBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

extension View {
    func bottomBarPadding() -> some View {
        modifier(BottomBarPadding())
    }
}

private struct BottomBarPadding: ViewModifier {
    @Environment(\.bottomBarInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, inset)
    }
}
