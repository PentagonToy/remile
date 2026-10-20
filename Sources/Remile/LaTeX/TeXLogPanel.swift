import SwiftUI

struct TeXLogPanel: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = LogState()
    private enum Tab: String, CaseIterable { case all = "All logs", errors = "Errors", warnings = "Warnings", terminal = "Terminal" }
    private final class LogState: ObservableObject { @Published var tab = Tab.all }
    private var entries: [TeXDiagnostic] {
        switch state.tab { case .errors: return project.diagnostics.filter { $0.severity == .error }; case .warnings: return project.diagnostics.filter { $0.severity == .warning }; default: return project.diagnostics }
    }
    var body: some View {
        VStack(spacing: 0) {
            if project.submissionCheck { Text("LaTeX only · 3 passes · no .bib/.bbl or BibTeX/Biber").font(RemileType.small).foregroundStyle(.secondary).padding(.top, 10) }
            Picker("Build output", selection: $state.tab) {
                ForEach(Tab.allCases, id: \.self) { tab in Text(title(tab)).tag(tab) }
            }.labelsHidden().pickerStyle(.segmented).padding(10)
            Divider()
            if state.tab == .terminal {
                ScrollView { Text(project.log.isEmpty ? "No compilation yet" : project.log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty { Text(project.compiling ? "Compiling…" : project.log.isEmpty ? "No compilation yet" : "No \(state.tab == .errors ? "errors" : state.tab == .warnings ? "warnings" : "diagnostics")").foregroundStyle(.secondary).padding(16) }
                        ForEach(entries) { entry in
                            Button { project.reveal(entry) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: entry.severity == .error ? "xmark.octagon" : "exclamationmark.triangle").foregroundStyle(RemileStyle.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.message).font(RemileType.callout).multilineTextAlignment(.leading).textSelection(.enabled)
                                        if let file = entry.file { Text(file + (entry.line.map { ":\($0)" } ?? "")).font(RemileType.small).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                            }.buttonStyle(.plain).help(entry.file == nil ? "Compiler diagnostic" : "Show source location")

                        }

                    }.padding(10)
                }
            }
        }.background(RemileStyle.sidebar)
    }
    private func title(_ tab: Tab) -> String {
        let count = tab == .errors ? project.diagnostics.filter { $0.severity == .error }.count : tab == .warnings ? project.diagnostics.filter { $0.severity == .warning }.count : project.diagnostics.count
        return tab == .terminal ? tab.rawValue : "\(tab.rawValue) \(count)"
    }
}
