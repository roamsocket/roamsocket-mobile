import SwiftUI

/// Dark theme tokens matching the Claude Code mobile screenshots.
enum Theme {
    // Backgrounds
    static let background = Color(hex: 0x0D0D0D)
    static let surface = Color(hex: 0x1A1A1A)
    static let surfaceElevated = Color(hex: 0x242424)
    static let field = Color(hex: 0x1E1E1E)

    // Text
    static let textPrimary = Color(hex: 0xF5F5F4)
    static let textSecondary = Color(hex: 0x9A9A97)
    static let textTertiary = Color(hex: 0x6B6B68)

    // Accents
    static let accent = Color(hex: 0xC96442)        // orange send button / highlights
    static let selection = Color(hex: 0x3B82F6)     // blue checkmark
    static let separator = Color(hex: 0x2A2A2A)
    static let codeToken = Color(hex: 0xD98E5B)

    // Radii
    static let pillRadius: CGFloat = 22
    static let cardRadius: CGFloat = 16
    static let sheetRadius: CGFloat = 28
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
