import AppKit

/// Okabe–Ito CUD palette. Opacity belongs to markup, never to the colour definition.
enum HighlightColor: String, CaseIterable, Identifiable, Sendable {
    case yellow, orange, skyBlue, bluishGreen, blue, vermilion, reddishPurple, black
    var id: Self { self }
    var name: String {
        switch self {
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .skyBlue: return "Sky blue"
        case .bluishGreen: return "Bluish green"
        case .blue: return "Blue"
        case .vermilion: return "Vermilion"
        case .reddishPurple: return "Reddish purple"
        case .black: return "Black"
        }
    }
    var hex: UInt32 {
        switch self {
        case .yellow: return 0xF0E442
        case .orange: return 0xE69F00
        case .skyBlue: return 0x56B4E9
        case .bluishGreen: return 0x009E73
        case .blue: return 0x0072B2
        case .vermilion: return 0xD55E00
        case .reddishPurple: return 0xCC79A7
        case .black: return 0x000000
        }
    }
    var color: NSColor { NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1) }
}
