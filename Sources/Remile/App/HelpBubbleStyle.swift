import Foundation

/// Shared design tokens, also available to other apps in others/templates/help.
struct HelpBubbleStyle: Decodable {
    let schemaVersion: Int
    let width: Double
    let padding: Double
    let fontSize: Double
    let hoverDelayMilliseconds: Int
    let animationSeconds: Double
    static let standard: HelpBubbleStyle = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Templates/Help/bubble.json"), root.appendingPathComponent("others/templates/help/bubble.json")]
        for url in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let style = try? JSONDecoder().decode(Self.self, from: data), style.valid { return style }
        }
        return Self(schemaVersion: 1, width: 320, padding: 13, fontSize: 14, hoverDelayMilliseconds: 180, animationSeconds: 0.15)
    }()
    private var valid: Bool {
        schemaVersion == 1 && (200...480).contains(width) && (8...24).contains(padding) && (12...20).contains(fontSize) && (0...1000).contains(hoverDelayMilliseconds) && (0...0.5).contains(animationSeconds)
    }
}
