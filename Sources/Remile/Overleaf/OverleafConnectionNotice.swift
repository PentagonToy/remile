import SwiftUI

struct OverleafConnectionNotice: View {
    static let key = "overleaf.connectionNotice.version"
    static let version = 1
    static func accepted(in defaults: UserDefaults = .standard) -> Bool { defaults.integer(forKey: key) == version }
    let agree: () -> Void
    let disagree: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing * 2) {
            Text("Connect to Overleaf?").font(RemileType.heading)
            Text("remile. is independent of Overleaf. Some connections, including Live, use unofficial interfaces.")
            Text("Service terms or changes may restrict or stop access. You use this connection at your own risk.")
            HStack {
                Link(destination: URL(string: "https://www.overleaf.com/legal")!) {
                    Text("Overleaf terms").foregroundStyle(RemileStyle.accent)
                }.font(RemileType.caption)
                Spacer()
                Button("Disagree", action: disagree).keyboardShortcut(.cancelAction)
                Button("Agree", action: agree).keyboardShortcut(.defaultAction)
            }
        }.fixedSize(horizontal: false, vertical: true).padding(RemileControl.rowSpacing * 2)
            .frame(width: 440).background(RemileStyle.background).tint(RemileStyle.accent)
    }
}
