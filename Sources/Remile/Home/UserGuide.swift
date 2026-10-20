import SwiftUI

struct UserGuide: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var more = false }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("A quiet place to work").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card("AI", "apple.intelligence", "Choose Apple Intelligence, ChatGPT or Manual. A dot on ChatGPT means connect or unlock. A dot on Apple Intelligence means automatic fallback to this Mac.")
                    card("Your documents", "lock.shield", "Keyword search and Apple Intelligence stay on this Mac. ChatGPT sends your question and document context when you ask. Manual turns AI off.")
                    card("Library search", "books.vertical", "Add a PDF or Markdown folder in Search → Library. Indexing runs on this Mac. Search shows the top 200 matches and flags pages without indexed text.")
                    DisclosureGroup("More features", isExpanded: $state.more) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    card("ChatGPT plan", "person.crop.circle", RemileHints.chatGPTPlan + " Plus usage is shared across connected apps.")
                    card("Ask", "text.bubble", "Ask about your PDF, Markdown or search results. Source links take you back to the passage.")
                    card("Suggestions", "text.badge.checkmark", "Double-click a word for alternatives. Review a spelling or grammar suggestion before accepting it.")
                    card("Review edits", "eye", RemileHints.edits(true) + ". Undo restores your text.")
                    card("Collections", "square.stack.3d.up", "Group files without moving them. Drag files or collections to organise them. The collection button beside Files shows or hides these groups.")
                    card("Sync", "arrow.triangle.2.circlepath", "Green means matching. Orange means changes can combine. Red means a conflict needs your choice. Review before publishing.")
                    card("History", "clock.arrow.circlepath", RemileHints.history(false) + ". Connected projects use Overleaf history.")
                    card("Build logs", "terminal", RemileHints.logs(false) + ". After editing, compile again to refresh the result.")
                    card("Compile", "play.fill", "⌘Return builds the PDF. Compile again after editing. Use Suggest fix beside an error or warning to review a proposed edit.")
                    card("Export", "square.and.arrow.up", "Save your PDF or a ZIP of the project source. Removing a project from the library only removes its local copy.")
                    }.padding(.top, 12)
                    }.font(RemileType.callout).padding(.top, 4)
                }
            }
            Text("Hover over a toolbar icon for a short hint.").font(RemileType.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 600, height: 570).background(RemileStyle.background)
    }
    private func card(_ title: String, _ symbol: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(RemileType.heading).foregroundStyle(RemileStyle.accent)
            Text(detail).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}
