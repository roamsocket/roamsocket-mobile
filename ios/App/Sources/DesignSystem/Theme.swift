import SwiftUI

/// Dark theme tokens shared with the Electron desktop client.
/// Cool blueish-grey surfaces with a soft blue accent (`#6aa9ff`).
enum Theme {
    // Backgrounds — match desktop --bg / --bg-elev / --bg-elev-2
    static let background = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x14181D)
    static let surfaceElevated = Color(hex: 0x1B2026)
    static let field = Color(hex: 0x0E1216)

    // Text — match desktop --text / --text-dim / --text-mute
    static let textPrimary = Color(hex: 0xE8ECF1)
    static let textSecondary = Color(hex: 0x9AA3AD)
    static let textTertiary = Color(hex: 0x6B727B)

    // Accents
    static let accent = Color(hex: 0x6AA9FF)        // primary actions / send
    static let selection = Color(hex: 0x6AA9FF)     // selected checkmark
    static let separator = Color(hex: 0x262C34)
    static let codeToken = Color(hex: 0x8BB8FF)

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
