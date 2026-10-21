import SwiftUI
import UniformTypeIdentifiers

struct OverleafComments: View {
    @ObservedObject var library: OverleafLibrary
    let connection: OverleafConnection
    let close: () -> Void
    @StateObject private var state = State()
    private final class State: ObservableObject { @Published var busy = false; @Published var error: String?; @Published var signIn = false; @Published var needsSignIn = false }
    private var archive: OverleafThreadArchive? { library.comments[connection.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.remileHelp("Refresh comments").disabled(state.busy)
                Menu { Button("Markdown…") { export(json: false) }; Button("JSON…") { export(json: true) } } label: { Image(systemName: "square.and.arrow.up") }.disabled(archive == nil)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            if let error = state.error {
                HStack { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning); Spacer(); if state.needsSignIn { Button("Sign in") { state.signIn = true } } }
            }
            if let archive, archive.threads.isEmpty {
                ContentUnavailableView("No comments", systemImage: "text.bubble").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(archive?.threads ?? []) { thread in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(thread.resolved ? "Resolved" : "Comment", systemImage: thread.resolved ? "checkmark.bubble" : "text.bubble").font(RemileType.caption).foregroundStyle(thread.resolved ? RemileStyle.success : RemileStyle.ink.opacity(0.6))
                            ForEach(thread.messages) { message in
                                VStack(alignment: .leading, spacing: 6) { Text(message.author).font(RemileType.caption.weight(.semibold)); Text(message.text).textSelection(.enabled) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background((thread.resolved ? RemileStyle.success : RemileStyle.accent).opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(24).frame(width: 520, height: 440).background(RemileStyle.background)
            .task { await refresh() }
            .sheet(isPresented: $state.signIn, onDismiss: { Task { await refresh() } }) { OverleafSignIn(profile: connection.profileID) { state.signIn = false } }
    }
    private func refresh() async {
        guard !state.busy else { return }; state.busy = true; state.error = nil; state.needsSignIn = false
        do { library.comments[connection.id] = try await OverleafWebClient.comments(connection) }
        catch { state.error = error.localizedDescription; state.needsSignIn = (error as? OverleafWebClient.Failure) == .signIn }
        state.busy = false
    }
    private func export(json: Bool) {
        guard let archive else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = json ? [.json] : [.remileMarkdown]
        panel.nameFieldStringValue = connection.name.replacingOccurrences(of: "/", with: "-") + " comments." + (json ? "json" : "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try archive.data(json: json).write(to: url, options: .atomic) } catch { state.error = error.localizedDescription; state.needsSignIn = (error as? OverleafWebClient.Failure) == .signIn }
    }
}
