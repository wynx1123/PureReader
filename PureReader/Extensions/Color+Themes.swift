import SwiftUI

// MARK: - Apple Books–inspired design tokens

enum PRTheme {
    static let shelfBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardFill = Color(uiColor: .systemBackground)

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    static let coverCorner: CGFloat = 5
    static let cardCorner: CGFloat = 12
    static let coverAspect: CGFloat = 2.0 / 3.0

    static let gridMin: CGFloat = 108
    static let gridMax: CGFloat = 148
    static let gridSpacing: CGFloat = 18

    static let touch: CGFloat = 44

    static func coverPalette(for title: String) -> (top: Color, bottom: Color) {
        let palette: [(Color, Color)] = [
            (Color(red: 0.45, green: 0.52, blue: 0.62), Color(red: 0.28, green: 0.33, blue: 0.42)),
            (Color(red: 0.55, green: 0.42, blue: 0.38), Color(red: 0.35, green: 0.25, blue: 0.22)),
            (Color(red: 0.40, green: 0.48, blue: 0.42), Color(red: 0.25, green: 0.32, blue: 0.28)),
            (Color(red: 0.50, green: 0.42, blue: 0.55), Color(red: 0.32, green: 0.26, blue: 0.38)),
            (Color(red: 0.48, green: 0.45, blue: 0.36), Color(red: 0.30, green: 0.28, blue: 0.22)),
            (Color(red: 0.38, green: 0.45, blue: 0.55), Color(red: 0.22, green: 0.28, blue: 0.38)),
            (Color(red: 0.58, green: 0.48, blue: 0.40), Color(red: 0.38, green: 0.30, blue: 0.24)),
            (Color(red: 0.42, green: 0.40, blue: 0.48), Color(red: 0.26, green: 0.24, blue: 0.32))
        ]
        let hash = abs(title.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[hash % palette.count]
    }
}

// MARK: - Reader page backgrounds

extension Color {
    static let readerWhite = Color(red: 1, green: 1, blue: 1)
    static let readerCream = Color(red: 0xF7 / 255, green: 0xF0 / 255, blue: 0xE3 / 255)
    static let readerGreen = Color(red: 0xD5 / 255, green: 0xE0 / 255, blue: 0xC6 / 255)
    static let readerDark = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x18 / 255)
    static let readerPaper = Color(red: 0xF5 / 255, green: 0xEF / 255, blue: 0xE0 / 255)
    static let readerParchment = Color(red: 0xEB / 255, green: 0xDF / 255, blue: 0xC8 / 255)

    static func readerBackground(_ type: BackgroundType) -> Color {
        switch type {
        case .white: return .readerWhite
        case .cream: return .readerCream
        case .green: return .readerGreen
        case .dark: return .readerDark
        case .paperTexture: return .readerPaper
        case .parchment: return .readerParchment
        }
    }

    static func readerForeground(_ type: BackgroundType) -> Color {
        switch type {
        case .dark:
            return Color(red: 0.90, green: 0.90, blue: 0.92)
        default:
            return Color(red: 0.14, green: 0.13, blue: 0.12)
        }
    }

    static func readerSecondary(_ type: BackgroundType) -> Color {
        readerForeground(type).opacity(0.55)
    }
}
