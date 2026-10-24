import AppKit

/// Page coordinates use points from the top-left, independent of zoom and window size.
struct WriterObject: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case line, rectangle, image, table }
    enum Arrow: String, Codable, CaseIterable { case none = "None", open = "Open", filled = "Filled" }
    var id = UUID()
    var kind: Kind
    var page = 0
    var start = CGPoint(x: 90, y: 110)
    var end = CGPoint(x: 290, y: 190)
    var hex: UInt32 = 0x0072B2
    var width: Double = 1.5
    var filled = false
    var startArrow: Arrow = .none
    var endArrow: Arrow = .none
    var rows = 3
    var columns = 3
    var cells = Array(repeating: "", count: 9)
    var imageData: Data?
    var text = ""
    var font = "Times New Roman"
    var fontSize = 12.0
    var alignment = 0
    var bold: Bool?
    var italic: Bool?
    var locked: Bool?
    var wrapsText: Bool?
    var fillHex: UInt32?
    var fillOpacity: Double?
    var textFont: NSFont { WriterFont.styled(font, size: fontSize, bold: bold == true, italic: italic == true) }
    var bounds: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(end.x - start.x)), height: max(1, abs(end.y - start.y))) }
}

enum WriterPalette: String, CaseIterable, Identifiable {
    case okabeIto = "Okabe–Ito", ibm = "IBM Carbon", bright = "Paul Tol Bright", muted = "Paul Tol Muted"
    var id: Self { self }
    var colours: [UInt32] {
        switch self {
        case .okabeIto: return [0x000000, 0xE69F00, 0x56B4E9, 0x009E73, 0xF0E442, 0x0072B2, 0xD55E00, 0xCC79A7]
        case .ibm: return [0x6929C4, 0x1192E8, 0x005D5D, 0x9F1853, 0xFA4D56, 0x570408, 0x198038, 0x002D9C, 0xEE538B, 0xB28600, 0x009D9A, 0x012749, 0x8A3800, 0xA56EFF]
        case .bright: return [0x4477AA, 0xEE6677, 0x228833, 0xCCBB44, 0x66CCEE, 0xAA3377, 0xBBBBBB]
        case .muted: return [0xCC6677, 0x332288, 0xDDCC77, 0x117733, 0x88CCEE, 0x882255, 0x44AA99, 0x999933, 0xAA4499]
        }
    }
    static func colour(_ hex: UInt32) -> NSColor { NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1) }
    static func hex(_ colour: NSColor) -> UInt32 {
        let c = colour.usingColorSpace(.sRGB) ?? .black
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }
}

enum WriterFont: String, CaseIterable, Identifiable {
    case times = "Times New Roman", sans = "Sans-serif", helvetica = "Helvetica", georgia = "Georgia"
    var id: Self { self }
    var family: String { self == .sans ? "Arial" : rawValue }
    static func styled(_ family: String, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }
    func font(size: Double) -> NSFont { NSFont(name: family, size: size) ?? .systemFont(ofSize: size) }
}


enum WriterList: String, CaseIterable, Identifiable {
    case none = "None", bullet = "•", dash = "–", circle = "○", square = "■", numbers = "1, 2, 3", letters = "a, b, c", upperLetters = "A, B, C", roman = "i, ii, iii", upperRoman = "I, II, III"
    var id: Self { self }
    var format: NSTextList.MarkerFormat? {
        switch self {
        case .none: nil
        case .bullet: .disc
        case .dash: .hyphen
        case .circle: .circle
        case .square: .square
        case .numbers: .decimal
        case .letters: .lowercaseAlpha
        case .upperLetters: .uppercaseAlpha
        case .roman: .lowercaseRoman
        case .upperRoman: .uppercaseRoman
        }
    }
}

extension WriterList {
    static func marker(_ list: NSTextList, number: Int) -> String {
        let numbered: Set<NSTextList.MarkerFormat> = [.decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseRoman, .uppercaseRoman]
        return list.marker(forItemNumber: number) + (numbered.contains(list.markerFormat) ? "." : "") + "\t"
    }
}
