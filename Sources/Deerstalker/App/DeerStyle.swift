import AppKit
import SwiftUI

/// Authored artwork swatches: slate #222C35, brick #A13F3B, paper #F0E7D7.
enum DeerStyle {
    static let slate = NSColor(red: 35 / 255, green: 33 / 255, blue: 32 / 255, alpha: 1)
    static let brick = NSColor(red: 161 / 255, green: 63 / 255, blue: 59 / 255, alpha: 1)
    static let paper = NSColor(red: 240 / 255, green: 231 / 255, blue: 215 / 255, alpha: 1)
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let background = adaptive(light: paper, dark: slate)
    static let ink = adaptive(light: slate, dark: paper)
    // Cream keeps small controls legible against slate; brick remains the brand colour.
    static let accent = adaptive(light: brick, dark: NSColor(red: 0.86, green: 0.40, blue: 0.35, alpha: 1))
    static let brand = Color(nsColor: brick)
    static let sourceLinked = adaptive(light: NSColor(red: 0, green: 114 / 255, blue: 178 / 255, alpha: 1), dark: NSColor(red: 86 / 255, green: 180 / 255, blue: 233 / 255, alpha: 1))
    static let sourceUnverified = Color(nsColor: NSColor(red: 0, green: 158 / 255, blue: 115 / 255, alpha: 1))
    static let surface = adaptive(light: paper.blended(withFraction: 0.4, of: .white)!, dark: slate.blended(withFraction: 0.06, of: paper)!)
    static let sidebar = adaptive(light: paper.blended(withFraction: 0.045, of: slate)!, dark: slate.blended(withFraction: 0.13, of: .black)!)
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
            .tint(DeerStyle.accent).foregroundStyle(DeerStyle.ink)
            .onAppear { ReaderAppearance.apply(appearance) }
            .onChange(of: appearance) { _, value in ReaderAppearance.apply(value) }
    }
}

enum DeerArtwork {
    private static var cache: [String: NSImage] = [:]
    static func image(_ kind: String, dark: Bool) -> NSImage? {
        let name = "deerstalker_\(kind)_\(dark ? "dark" : "light")"
        if let image = cache[name] { return image }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).svg"),
                    sourceRoot.appendingPathComponent("others/\(kind == "banner" ? "banners" : "icons")/\(name).svg")]
        guard let image = urls.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        cache[name] = image
        return image
    }
}


enum DeerMotion {
    static let panel = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let navigation = Animation.spring(response: 0.38, dampingFraction: 0.9)
}

struct DeerPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
