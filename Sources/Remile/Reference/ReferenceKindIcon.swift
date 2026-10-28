import SwiftUI

struct ReferenceKindIcon: View {
    let kind: ReferenceKind
    var hasAttachment = false
    private static let podium: NSImage? = {
        let name = "reference-conference.svg"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Brand/" + name), root.appendingPathComponent("others/symbols/reference/" + name)]
        guard let image = urls.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: RemileControl.iconSlot, height: RemileControl.iconSlot)
        return image
    }()
    var body: some View {
        Group {
            if kind == .conference, let image = Self.podium { Image(nsImage: image) }
            else { SymbolIcon(systemName: kind.symbol).symbolRenderingMode(.monochrome) }
        }.frame(width: RemileControl.iconSlot, height: RemileControl.iconSlot)
            .frame(width: 18, height: 18).foregroundStyle(RemileStyle.accent)
            .overlay(alignment: .bottomTrailing) {
                if hasAttachment {
                    Circle().fill(RemileStyle.accent).frame(width: 5, height: 5)
                        .padding(2).background(RemileStyle.background, in: Circle()).offset(x: 4, y: 3)
                }
            }.accessibilityLabel(kind.label + (hasAttachment ? ", PDF attached" : ""))
    }
}
