import SwiftUI

struct TeXLogPanel: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = LogState()
    private enum Tab: String, CaseIterable { case all = "All logs", errors = "Errors", warnings = "Warnings", terminal = "Terminal" }
    private final class LogState: ObservableObject { @Published var tab = Tab.all }
    private var entries: [TeXDiagnostic] {
        switch state.tab { case .errors: return TeXDiagnostics.prioritised(project.diagnostics).filter { $0.severity == .error }; case .warnings: return TeXDiagnostics.prioritised(project.diagnostics).filter { $0.severity == .warning }; default: return TeXDiagnostics.prioritised(project.diagnostics) }
    }
    var body: some View {
        let firstErrorID = TeXDiagnostics.primaryError(project.diagnostics)?.id
        VStack(spacing: 0) {
            if project.setupIssue != nil || !TeXConfiguration.current.missingTools(buffers: project.buffers).isEmpty {
                HStack { Spacer(); Button("TeX setup") { project.setupNeeded = true }.remileHelp("View missing tools and packages") }.padding(.horizontal, 10).padding(.top, 8)
            }
            if project.pdf != nil && !project.outputCurrent && !project.compiling && !project.log.isEmpty { Text("Previous build · recompile changes").font(RemileType.caption).foregroundStyle(RemileStyle.warning).padding(.top, 8) }
            if project.submissionCheck { Text("LaTeX only · 3 passes · no .bib/.bbl or BibTeX/Biber").font(RemileType.small).foregroundStyle(.secondary).padding(.top, 10) }
            VStack(alignment: .leading, spacing: 6) {
                RemileSegmentedControl(title: "Build output", selection: $state.tab, options: Tab.allCases, label: { $0 == .all ? "All" : $0.rawValue })
                if state.tab != .terminal { Text(title(state.tab)).font(RemileType.small).foregroundStyle(.secondary) }
            }.padding(10)
            Divider()
            if state.tab == .terminal {
                ScrollView { Text(project.log.isEmpty ? "No compilation yet" : project.log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty { Text(project.compiling ? "Compiling…" : project.log.isEmpty ? "No compilation yet" : "No \(state.tab == .errors ? "errors" : state.tab == .warnings ? "warnings" : "diagnostics")").foregroundStyle(.secondary).padding(16) }
                        ForEach(entries) { entry in
                            TeXDiagnosticRow(project: project, entry: entry, checkFirst: entry.id == firstErrorID)


                        }

                    }.padding(10)
                }
            }
        }.font(RemileType.control).background(RemileStyle.sidebar)
            .onAppear { if project.compileFailed { state.tab = .errors } }
            .onChange(of: project.compileFailed) { if project.compileFailed { state.tab = .errors } }
    }
    private func title(_ tab: Tab) -> String {
        let count = tab == .errors ? project.diagnostics.filter { $0.severity == .error }.count : tab == .warnings ? project.diagnostics.filter { $0.severity == .warning }.count : project.diagnostics.count
        return tab == .terminal ? tab.rawValue : "\(tab.rawValue) \(count)"
    }
}

private struct TeXDiagnosticRow: View {
    @ObservedObject var project: TeXProject
    let entry: TeXDiagnostic
    var checkFirst = false
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var connection = ChatGPTConnection.shared
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @StateObject private var presentation = Presentation()
    private final class Presentation: ObservableObject { @Published var showing = false }
    private var location: TeXSync.SourceLocation? { project.diagnosticLocation(entry) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if checkFirst { Text("Check first").font(RemileType.caption.weight(.semibold)).foregroundStyle(RemileStyle.accent) }
            Button { project.reveal(entry) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.severity == .error ? "xmark.octagon" : "exclamationmark.triangle").foregroundStyle(RemileStyle.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.displayMessage).font(RemileType.callout).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if let file = entry.file { Text(file + (entry.line.map { ":\($0)" } ?? "")).font(RemileType.small).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    if location != nil { Spacer(minLength: 8); Image(systemName: "scope").foregroundStyle(RemileStyle.accent).accessibilityHidden(true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).remileHelp(location == nil ? "Build diagnostic" : "Go to source")
            if entry.severity != .info && !entry.isBuildSummary {
                HStack { Spacer(); Button { presentation.showing = true } label: { HStack(spacing: 5) { GPTMark(); Text("Suggest fix").font(RemileType.caption) } }
                    .disabled(project.compiling || usage.active || usage.reason != nil || provider == "Off").opacity(usage.reason != nil ? 0.45 : 1).remileHelp(provider == "Off" ? "AI off" : usage.reason ?? "Suggest a fix")
                    .popover(isPresented: $presentation.showing, arrowEdge: .leading) { TeXChatGPTReview(project: project, diagnostic: entry) }
                }
            }
        }.padding(12).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
    }
}
