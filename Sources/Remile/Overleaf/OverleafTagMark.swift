import SwiftUI
import AppKit

/// A narrow colour cue keeps long project titles readable. Names remain one click away.
struct OverleafTagMark: View {
    let tags: [OverleafWebClient.Tag]
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var expanded = false }
    var body: some View {
        if !tags.isEmpty {
            Button { state.expanded.toggle() } label: {
                HStack(spacing: 2) {
                    ForEach(tags.prefix(3)) { tag in Capsule().fill(Self.tint(tag.color)).frame(width: 3, height: 18) }
                    if tags.count > 3 { Text("+\(tags.count - 3)").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 3).frame(minWidth: 12, minHeight: 24)
            }.buttonStyle(.plain).accessibilityLabel("Project tags: " + tags.map(\.name).joined(separator: ", "))
                .popover(isPresented: $state.expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Overleaf tags").font(RemileType.callout.weight(.semibold))
                        ForEach(tags) { tag in HStack { Capsule().fill(Self.tint(tag.color)).frame(width: 3, height: 16); Text(tag.name).font(RemileType.caption) } }
                    }.padding(16).frame(maxWidth: 320, alignment: .leading).background(RemileStyle.background)
                }
        }
    }
    static func tint(_ value: String?) -> Color {
        guard let value else { return RemileStyle.accent }
        var colour: NSColor?
        if value.range(of: "^#[a-fA-F0-9]{6}$", options: .regularExpression) != nil, let rgb = Int(value.dropFirst(), radix: 16) {
            colour = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
        } else if value.range(of: "^hsl\\([0-9]{1,3}, 70%, 45%\\)$", options: .regularExpression) != nil,
                  let hue = Double(value.dropFirst(4).prefix(while: { $0.isNumber })) {
            colour = NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.7, brightness: 0.77, alpha: 1)
        }
        guard let rgb = colour?.usingColorSpace(.deviceRGB) else { return RemileStyle.accent }
        return Color(hue: Double(rgb.hueComponent), saturation: min(0.48, Double(rgb.saturationComponent)), brightness: 0.78)
    }
}
