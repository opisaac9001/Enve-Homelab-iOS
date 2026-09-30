import Combine
import SwiftUI

struct ColorSet {
    let background: Color
    let card: Color
    let cardStroke: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    enum AppTheme: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        case oled = "OLED"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            case .oled: "True Black (OLED)"
            }
        }
    }

    private static let selectedThemeKey = "envehomelab.selectedAppTheme"

    @Published var selectedTheme: AppTheme {
        didSet { UserDefaults.standard.set(selectedTheme.rawValue, forKey: Self.selectedThemeKey) }
    }

    private init() {
        selectedTheme = UserDefaults.standard.string(forKey: Self.selectedThemeKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    var preferredColorScheme: ColorScheme? {
        switch selectedTheme {
        case .system: nil
        case .light: .light
        case .dark, .oled: .dark
        }
    }

    func colors(for scheme: ColorScheme) -> ColorSet {
        if selectedTheme == .oled {
            return ColorSet(
                background: .black,
                card: Color(white: 0.08),
                cardStroke: Color(white: 0.16),
                text: .white,
                secondaryText: Color(white: 0.68),
                tertiaryText: Color(white: 0.46)
            )
        }
        if scheme == .dark {
            return ColorSet(
                background: Color(red: 0.05, green: 0.05, blue: 0.06),
                card: Color(white: 0.12).opacity(0.82),
                cardStroke: Color.white.opacity(0.07),
                text: .white,
                secondaryText: Color(white: 0.7),
                tertiaryText: Color(white: 0.5)
            )
        }
        return ColorSet(
            background: Color(red: 0.96, green: 0.95, blue: 0.94),
            card: Color.white.opacity(0.86),
            cardStroke: Color.black.opacity(0.06),
            text: Color(.label),
            secondaryText: Color(.secondaryLabel),
            tertiaryText: Color(.tertiaryLabel)
        )
    }
}

extension Color {
    static let enveAccent = Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255)
}

extension Health {
    var color: Color {
        switch self {
        case .ok: .green
        case .unknown: .secondary
        case .warning: .yellow
        case .critical: .red
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .unknown: "circle.dashed"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .ok: "Healthy"
        case .unknown: "Unknown"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}
