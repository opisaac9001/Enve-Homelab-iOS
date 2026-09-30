import SwiftUI

struct DynamicBackground: View {
    @State private var animate = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        let isOLED = theme.selectedTheme == .oled
        ZStack {
            colors.background

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    Circle()
                        .fill(Color.enveAccent.opacity(isOLED ? 0.16 : 0.24))
                        .frame(width: w * 0.95)
                        .blur(radius: 70)
                        .offset(x: animate ? w * 0.2 : w * 0.32, y: animate ? -h * 0.18 : -h * 0.28)
                        .animation(.easeInOut(duration: 30).repeatForever(autoreverses: true), value: animate)

                    Circle()
                        .fill(Color(red: 0.9, green: 0.36, blue: 0.12).opacity(isOLED ? 0.08 : 0.13))
                        .frame(width: w * 0.8)
                        .blur(radius: 80)
                        .offset(x: animate ? -w * 0.12 : -w * 0.26, y: animate ? h * 0.22 : h * 0.3)
                        .animation(.easeInOut(duration: 36).repeatForever(autoreverses: true), value: animate)
                }
                .frame(width: w, height: h)
                .clipped()
                .drawingGroup()
            }
        }
        .accessibilityHidden(true)
        .onAppear { animate = scenePhase == .active && !reduceMotion }
        .onChange(of: scenePhase) { _, phase in animate = phase == .active && !reduceMotion }
    }
}

private struct EnveScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { DynamicBackground().ignoresSafeArea() }
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func enveScreen() -> some View {
        modifier(EnveScreenModifier())
    }
}
