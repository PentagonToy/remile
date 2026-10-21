import SwiftUI

final class UserGuidePresentation: ObservableObject { @Published var more = false }

struct UserGuide: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: UserGuidePresentation
    init(presentation: UserGuidePresentation? = nil) { _state = StateObject(wrappedValue: presentation ?? UserGuidePresentation()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Text(RemileBrand.tagline).font(.title2.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button("Tour") { dismiss(); NotificationCenter.default.post(name: .remileReplayTour, object: nil) }.fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).fixedSize()
            }
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card("AI", "apple.intelligence", "Choose Manual, Apple Intelligence or ChatGPT. Enable local fallback when ChatGPT is unavailable.")
                    card("Your documents", "lock.shield", "Search and Apple Intelligence stay on this Mac. ChatGPT receives context only when you ask. Work offline pauses online services.")
                    card("Library search", "books.vertical", "Add PDF or Markdown folders in Search → Library. Find up to 200 matches, or boost questions with Apple Intelligence. Standard search works offline.")
                    DisclosureGroup("More features", isExpanded: $state.more) {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                    card("ChatGPT plan", "person.crop.circle", "Use your ChatGPT plan with no separate API bill from remile. Usage follows your ChatGPT settings and limits.")
                    card("Ask", "text.bubble", "Ask about your PDF, Markdown or search results. Source links take you back to the passage.")
                    }
                    GridRow {
                    card("Suggestions", "text.badge.checkmark", "Double-click a word for alternatives. Review a spelling or grammar suggestion before accepting it.")
                    card("Review edits", "eye", "Show or hide edits made by AI or an agent. Undo restores your text.")
                    }
                    GridRow {
                    card("Collections", "square.stack.3d.up", "Group files without moving them. Drag to organise; use the collection button beside Files to show groups.")
                    card("Sync", "arrow.triangle.2.circlepath", "Green: in sync. Orange: mergeable changes. Red: choose a resolution. Local edits sync online; remote changes wait for review.")
                    }
                    GridRow {
                    card("History", "clock.arrow.circlepath", "Compare earlier local versions. Connected projects use Overleaf history.")
                    card("Build logs", "terminal", "Inspect compiler errors, warnings and terminal output. Compile again after editing.")
                    }
                    GridRow {
                    card("Compile", "play.fill", "Press ⌘Return to build the PDF. Use Suggest fix to review a proposed correction.")
                    card("Export", "square.and.arrow.up", "Save the PDF or download project sources as a ZIP. Removing a library project keeps its remote copy.")
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
