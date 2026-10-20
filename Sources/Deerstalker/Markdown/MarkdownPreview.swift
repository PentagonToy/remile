import SwiftUI

struct MarkdownPreview: View {
    let source: String
    var scale: CGFloat = 1
    var wide = false
    @StateObject private var rendering = Rendering()

    final class Rendering: ObservableObject {
        @Published var blocks: [MarkdownBlock] = []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(rendering.blocks) { block in
                    switch block.style {
                    case .heading(let level):
                        Text(block.text).font(.system(size: headingSize(level) * scale, weight: .bold)).padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                    case .code:
                        ScrollView(.horizontal) {
                            Text(block.text).font(.system(size: 15 * scale, design: .monospaced)).padding(14)
                        }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    case .quote:
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(width: 3)
                            Text(block.text).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    case .list(let marker, let depth):
                        HStack(alignment: .top, spacing: 10) {
                            Text(marker).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                            Text(block.text)
                        }.padding(.leading, CGFloat(max(0, depth - 1)) * 20)
                    case .paragraph:
                        Text(block.text)
                    }
                }
            }
            .font(.system(size: 16 * scale))
            .textSelection(.enabled)
            .frame(maxWidth: wide ? .infinity : 760 * scale, alignment: .leading)
            .frame(maxWidth: .infinity).padding(32)
        }
        .background(.background)
        .accessibilityLabel("Markdown preview")
        .task(id: source) {
            // Coalesce split-view keystrokes before parsing; one source owns every mode.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            rendering.blocks = MarkdownBlock.parse(source)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 30; case 2: return 25; case 3: return 21; default: return 18 }
    }
}
