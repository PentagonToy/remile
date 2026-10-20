import AppKit
import SwiftUI

/// Canonical colours from the user's remile. SVG artwork.
enum RemileStyle {
    static let slate = NSColor(srgbRed: 32/255, green: 44/255, blue: 53/255, alpha: 1)
    static let paper = NSColor(srgbRed: 243/255, green: 239/255, blue: 231/255, alpha: 1)
    static let ivory = NSColor(srgbRed: 243/255, green: 234/255, blue: 219/255, alpha: 1)
    static let gold = NSColor(srgbRed: 146/255, green: 107/255, blue: 50/255, alpha: 1)
    static let amber = NSColor(srgbRed: 214/255, green: 183/255, blue: 119/255, alpha: 1)
    static let navy = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 166/255, green: 179/255, blue: 187/255, alpha: 1) : NSColor(srgbRed: 86/255, green: 104/255, blue: 115/255, alpha: 1) }
    static let sage = NSColor(srgbRed: 0.53, green: 0.68, blue: 0.60, alpha: 1)
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let background = adaptive(light: paper, dark: slate)
    static let ink = adaptive(light: NSColor(srgbRed: 41/255, green: 57/255, blue: 68/255, alpha: 1), dark: ivory)
    static let accent = adaptive(light: gold, dark: amber)
    static let brand = accent
    static let sourceLinked = accent
    static let sourceUnverified = ink.opacity(0.5)
    static let success = adaptive(light: NSColor(srgbRed: 0.25, green: 0.46, blue: 0.36, alpha: 1), dark: sage)
    static let warning = adaptive(light: NSColor(srgbRed: 0.65, green: 0.35, blue: 0.16, alpha: 1), dark: NSColor(srgbRed: 0.83, green: 0.58, blue: 0.36, alpha: 1))
    static let surface = adaptive(light: paper.blended(withFraction: 0.4, of: .white)!, dark: slate.blended(withFraction: 0.06, of: ivory)!)
    static let sidebar = adaptive(light: paper.blended(withFraction: 0.045, of: slate)!, dark: slate.blended(withFraction: 0.13, of: .black)!)
    static let editorBar = adaptive(light: paper.blended(withFraction: 0.025, of: slate)!, dark: slate.blended(withFraction: 0.035, of: ivory)!)
}

enum ReaderAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    static let preference = "reader.appearance"
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    static func apply(_ value: String) {
        switch Self(rawValue: value) ?? .system {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct ReaderAppearanceModifier: ViewModifier {
    @AppStorage(ReaderAppearance.preference) private var appearance = ReaderAppearance.system.rawValue
    func body(content: Content) -> some View {
        content.preferredColorScheme((ReaderAppearance(rawValue: appearance) ?? .system).scheme)
            .tint(RemileStyle.accent).foregroundStyle(RemileStyle.ink).font(RemileType.body)
            .onAppear { ReaderAppearance.apply(appearance) }
            .onChange(of: appearance) { _, value in ReaderAppearance.apply(value) }
    }
}

enum RemileArtwork {
    private static var cache: [String: NSImage] = [:]
    static func image(_ kind: String, dark: Bool) -> NSImage? {
        let name = "remile_\(kind)_\(dark ? "dark" : "light")" + (kind == "icon" ? "_rounded" : "")
        if let image = cache[name] { return image }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).svg"),
                    sourceRoot.appendingPathComponent("others/\(kind == "icon" ? "icons" : "banners")/\(name).svg")]
        guard let image = urls.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        cache[name] = image
        return image
    }
}


enum RemileType {
    static let body = Font.system(size: 16)
    static let caption = Font.system(size: 14)
    static let small = Font.system(size: 13)
    static let callout = Font.system(size: 15)
    static let heading = Font.system(size: 17, weight: .semibold)
}

enum RemileRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let grip: CGFloat = 3
}

enum RemileMotion {
    static let disclosure = Animation.timingCurve(0.22, 0.7, 0.25, 1, duration: 0.36)
    static let panel = Animation.timingCurve(0.22, 0.7, 0.25, 1, duration: 0.36)
    static let navigation = Animation.timingCurve(0.22, 0.7, 0.25, 1, duration: 0.4)
}

struct RemilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}


enum DocumentTone {
    static func accent(pdf: Bool) -> Color { pdf ? RemileStyle.accent : RemileStyle.ink }
    static func surface(pdf: Bool) -> Color { pdf ? RemileStyle.surface : RemileStyle.sidebar }
}

struct RemileToolStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 32, minHeight: 32).background(Color.primary.opacity(0.001)).contentShape(.interaction, Rectangle())
            .background(configuration.isPressed ? RemileStyle.ink.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
