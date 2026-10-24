import SwiftUI

final class UserGuidePresentation: ObservableObject { @Published var more = false }

struct UserGuide: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: UserGuidePresentation
    init(presentation: UserGuidePresentation? = nil) { _state = StateObject(wrappedValue: presentation ?? UserGuidePresentation()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Text(RemileBrand.tagline).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Tour") { dismiss(); NotificationCenter.default.post(name: .remileReplayTour, object: nil) }.fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).fixedSize()
            }
            Link(destination: URL(string: "https://pentagontoy.github.io/remile/workspace-layout.html")!) {
                Label("Online guide", systemImage: "arrow.up.forward.square")
            }.font(RemileType.caption).remileHelp("Workspace controls and help on the web")
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card("AI", "apple.intelligence", "Choose AI in Settings. Apple Intelligence runs on this Mac.")
                    card("Your documents", "lock.shield", "Search stays on this Mac. ChatGPT receives context when you ask.")
                    card("Library search", "books.vertical", "Add folders in Search → Library, then search by keyword or question.")
                    DisclosureGroup("More features", isExpanded: $state.more) {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                    card("ChatGPT plan", "person.crop.circle", "No separate API bill from remile. Your ChatGPT plan and credit settings apply.")
                    card("Ask", "text.bubble", "Ask about a document. Follow source links back to the passage.")
                    }
                    GridRow {
                    card("Writing", "text.badge.checkmark", "Right-click a word for spelling corrections. Select prose to request proofreading.")
                    card("Review edits", "eye", "Show or hide edits made by AI or an agent. Undo restores your text.")
                    }
                    GridRow {
                    card("Collections", "square.stack.3d.up", "Group files without moving them. Drag to organise.")
                    card("Sync", "arrow.triangle.2.circlepath", "Private sync reviews remote changes. Live sync shares text edits as you write.")
                    }
                    GridRow {
                    card("History", "clock.arrow.circlepath", "Compare earlier local versions. Connected projects use Overleaf history.")
                    card("Build logs", "terminal", "Read compiler output, then edit and compile again.")
                    }
                    GridRow {
                    card("Compile", "play.fill", "Press ⌘Return to build the PDF. Use Suggest fix to review a proposed correction.")
                    card("Export", "square.and.arrow.up", "Save your PDF, project sources, comments or review questions.")
                    }
                    }.padding(.top, 12)
                    }.font(RemileType.callout).padding(.top, 4)
                }.frame(width: max(0, viewport.size.width - 28), alignment: .leading).padding(.trailing, 28)
            }.smoothScrolling().frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
            }
        }.padding(24).frame(width: 700, height: 620).background(RemileStyle.background)
    }
    private func card(_ title: String, _ symbol: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(RemileType.heading).foregroundStyle(RemileStyle.accent)
            Text(detail).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}
