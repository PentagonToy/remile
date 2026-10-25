import SwiftUI

final class UserGuidePresentation: ObservableObject { @Published var more = false }

struct UserGuide: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: UserGuidePresentation
    init(presentation: UserGuidePresentation? = nil) { _state = StateObject(wrappedValue: presentation ?? UserGuidePresentation()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("User guide").font(RemileType.windowTitle)
                Spacer()
                Button("Take a tour") { dismiss(); NotificationCenter.default.post(name: .remileReplayTour, object: nil) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(RemileBrand.tagline).font(RemileType.callout).foregroundStyle(RemileStyle.secondaryInk)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 0) {
                        workspace("PDF", "doc.richtext", "Read, annotate and copy images or tables.", "workspace/pdf.html")
                        Divider()
                        workspace("Search", "magnifyingglass", "Find passages across your folders.", "workspace/search.html")
                        Divider()
                        workspace("Reference", "books.vertical", "Keep papers, PDFs and citations together.", "reference.html")
                        Divider()
                        workspace("Writer", "text.alignleft", "Write and lay out a document.", "writer.html")
                        Divider()
                        workspace("Markdown", "square.and.pencil", "Write a note and preview as you go.", "workspace/markdown.html")
                        Divider()
                        workspace("LaTeX", "doc.text", "Create a project, compile and follow build errors.", "workspace/latex.html")
                        Divider()
                        workspace("Overleaf", "leaf", "Connect projects and review remote changes.", "workspace/overleaf.html")
                    }.padding(.horizontal, 14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.card))
                    DisclosureGroup("AI, privacy and history", isExpanded: $state.more) {
                        VStack(alignment: .leading, spacing: 16) {
                            detail("AI", "Choose AI in Settings. Apple Intelligence runs on this Mac. ChatGPT receives context when you ask.")
                            detail("ChatGPT plan", "No separate API bill from remile. Your ChatGPT plan and credit settings apply.")
                            detail("History", "Compare earlier local versions. Connected projects use Overleaf history.")
                        }.padding(.leading, 16).padding(.top, 12)
                    }
                    Link("All controls and shortcuts", destination: URL(string: "https://pentagontoy.github.io/remile/workspace-layout.html")!)
                }.padding(.trailing, 28)
            }.smoothScrolling()
        }.padding(24).font(RemileType.control).buttonStyle(RemileActionStyle()).frame(width: 700, height: 620).background(RemileStyle.background)
    }
    private func workspace(_ title: String, _ symbol: String, _ summary: String, _ path: String) -> some View {
        Link(destination: URL(string: "https://pentagontoy.github.io/remile/" + path)!) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(RemileStyle.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(RemileType.section).foregroundStyle(RemileStyle.ink)
                    Text(summary).font(RemileType.small).foregroundStyle(RemileStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(RemileType.small).foregroundStyle(RemileStyle.secondaryInk).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain).remileHelp("Open the \(title) guide on the web")
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(RemileType.section)
            Text(text).foregroundStyle(RemileStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
    }
}
