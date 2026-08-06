import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Appearance preference

/// User-selectable app appearance. Persisted via `AppStorage`.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    /// Cool blue-grey surfaces (current brand dark).
    case dark
    /// Pure black backgrounds (stock Apple OLED style).
    case oled
    /// Light surfaces with the same blue accent as dark.
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .oled: return "OLED"
        case .light: return "Light"
        }
    }

    var subtitle: String {
        switch self {
        case .dark: return "Cool blue-grey"
        case .oled: return "True black"
        case .light: return "White with blue accent"
        }
    }

    var systemImage: String {
        switch self {
        case .dark: return "moon.fill"
        case .oled: return "moon.stars.fill"
        case .light: return "sun.max.fill"
        }
    }

    /// System color scheme for controls, keyboards, and status bar.
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var palette: ThemePalette {
        switch self {
        case .dark: return .dark
        case .oled: return .oled
        case .light: return .light
        }
    }

    static let storageKey = "appAppearance.v1"
    static let `default`: AppAppearance = .dark

    static func resolve(rawValue: String?) -> AppAppearance {
        guard let rawValue, let value = AppAppearance(rawValue: rawValue) else {
            return .default
        }
        return value
    }
}

// MARK: - Palette

/// Concrete color tokens for one appearance.
struct ThemePalette {
    let background: Color
    let surface: Color
    let surfaceElevated: Color
    let field: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    let accent: Color
    let selection: Color
    let separator: Color
    let codeToken: Color

    /// Ink for labels/icons sitting on accent fills (always dark for contrast).
    let inkOnAccent: Color

    let colorScheme: ColorScheme

    /// Cool blue-grey — shared with the Electron desktop client.
    static let dark = ThemePalette(
        background: Color(hex: 0x0B0D10),
        surface: Color(hex: 0x14181D),
        surfaceElevated: Color(hex: 0x1B2026),
        field: Color(hex: 0x0E1216),
        textPrimary: Color(hex: 0xE8ECF1),
        textSecondary: Color(hex: 0x9AA3AD),
        textTertiary: Color(hex: 0x6B727B),
        accent: Color(hex: 0x6AA9FF),
        selection: Color(hex: 0x6AA9FF),
        separator: Color(hex: 0x262C34),
        codeToken: Color(hex: 0x8BB8FF),
        inkOnAccent: Color(hex: 0x0B0D10),
        colorScheme: .dark
    )

    /// Stock Apple OLED: pure black canvas, system greys for elevated layers.
    static let oled = ThemePalette(
        background: Color(hex: 0x000000),
        surface: Color(hex: 0x1C1C1E),
        surfaceElevated: Color(hex: 0x2C2C2E),
        field: Color(hex: 0x1C1C1E),
        textPrimary: Color(hex: 0xFFFFFF),
        textSecondary: Color(hex: 0x8E8E93),
        textTertiary: Color(hex: 0x636366),
        accent: Color(hex: 0x6AA9FF),
        selection: Color(hex: 0x6AA9FF),
        separator: Color(hex: 0x38383A),
        codeToken: Color(hex: 0x8BB8FF),
        inkOnAccent: Color(hex: 0x0B0D10),
        colorScheme: .dark
    )

    /// Light canvas with the same brand blue accent as dark.
    static let light = ThemePalette(
        background: Color(hex: 0xFFFFFF),
        surface: Color(hex: 0xF2F4F7),
        surfaceElevated: Color(hex: 0xE8ECF1),
        field: Color(hex: 0xEEF1F5),
        textPrimary: Color(hex: 0x0B0D10),
        textSecondary: Color(hex: 0x5C6570),
        textTertiary: Color(hex: 0x8B929A),
        accent: Color(hex: 0x6AA9FF),
        selection: Color(hex: 0x6AA9FF),
        separator: Color(hex: 0xD8DEE6),
        codeToken: Color(hex: 0x2B6FD6),
        inkOnAccent: Color(hex: 0x0B0D10),
        colorScheme: .light
    )
}

// MARK: - Theme (dynamic accessors)

/// App theme tokens. Colors follow the active `AppAppearance`.
///
/// Call `Theme.apply(_:)` when the preference changes (and once at launch).
/// Root views should also `.id` the appearance so SwiftUI rebuilds with the
/// new static colors.
enum Theme {
    /// Active appearance. Mutate only via `apply(_:)`.
    private(set) static var appearance: AppAppearance = .dark
    /// Active palette. Mutate only via `apply(_:)`.
    private(set) static var current: ThemePalette = .dark

    /// Apply a user appearance. Safe to call from app launch / preference change.
    static func apply(_ appearance: AppAppearance) {
        self.appearance = appearance
        current = appearance.palette
        applyUIKitControlChrome()
    }

    /// Keep system controls (segmented pickers, etc.) readable in every palette.
    /// Light mode otherwise often ends up with white label text on a light track.
    private static func applyUIKitControlChrome() {
        #if canImport(UIKit)
        let normal: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(textSecondary),
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
        ]
        // Selected segment uses the accent tint; ink must stay dark for contrast.
        let selected: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(inkOnAccent),
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        ]
        let control = UISegmentedControl.appearance()
        control.setTitleTextAttributes(normal, for: .normal)
        control.setTitleTextAttributes(selected, for: .selected)
        control.selectedSegmentTintColor = UIColor(accent)
        control.backgroundColor = UIColor(surfaceElevated)
        #endif
    }

    static var preferredColorScheme: ColorScheme { appearance.colorScheme }
    static var isLight: Bool { appearance == .light }

    // Backgrounds
    static var background: Color { current.background }
    static var surface: Color { current.surface }
    static var surfaceElevated: Color { current.surfaceElevated }
    static var field: Color { current.field }

    // Text
    static var textPrimary: Color { current.textPrimary }
    static var textSecondary: Color { current.textSecondary }
    static var textTertiary: Color { current.textTertiary }

    // Accents
    static var accent: Color { current.accent }
    static var selection: Color { current.selection }
    static var separator: Color { current.separator }
    static var codeToken: Color { current.codeToken }

    /// Dark ink for content drawn on accent fills (send buttons, primary CTAs).
    static var inkOnAccent: Color { current.inkOnAccent }

    // Radii (shared across appearances)
    static let pillRadius: CGFloat = 22
    static let cardRadius: CGFloat = 16
    static let sheetRadius: CGFloat = 28

    /// Hex strings for embedded HTML / non-SwiftUI surfaces.
    static var cssBackground: String {
        switch appearance {
        case .dark: return "#0B0D10"
        case .oled: return "#000000"
        case .light: return "#FFFFFF"
        }
    }

    static var cssSurface: String {
        switch appearance {
        case .dark: return "#14181D"
        case .oled: return "#1C1C1E"
        case .light: return "#F2F4F7"
        }
    }

    static var cssTextPrimary: String {
        switch appearance {
        case .dark: return "#E8ECF1"
        case .oled: return "#FFFFFF"
        case .light: return "#0B0D10"
        }
    }

    static var cssAccent: String { "#6AA9FF" }
    static var cssColorScheme: String { isLight ? "light" : "dark" }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
