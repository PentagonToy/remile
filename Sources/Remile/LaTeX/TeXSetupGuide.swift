import SwiftUI

struct TeXSetupGuide: View {
    let missing: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LaTeX is not ready").font(RemileType.heading)
            Text("Install with Homebrew, or choose your existing TeX folder in Project settings.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("brew install --cask mactex-no-gui").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install --cask mactex-no-gui", forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(RemileToolStyle()).remileHelp("Copy command")
            }.padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: RemileRadius.control).stroke(RemileStyle.ink.opacity(0.15)))
            Link("Installation help", destination: URL(string: "https://www.tug.org/mactex/")!).font(.callout)
        }.padding(20).frame(width: 370).background(RemileStyle.background)
    }
}
