import SwiftUI

struct TeXLogPanel: View {
    @ObservedObject var project: TeXProject
    @State private var tab = Tab.all

    private enum Tab: String, CaseIterable {
        case all = "All", errors = "Errors", warnings = "Warnings", info = "Info", terminal = "Terminal"

        var severity: TeXDiagnostic.Severity? {
            switch self {
            case .errors: .error
            case .warnings: .warning
            case .info: .info
            default: nil
            }
        }

        var emptyMessage: String {
            switch self {
            case .errors: "No errors"
            case .warnings: "No warnings"
            case .info: "No info messages"
            default: "No diagnostics"
            }
        }
    }

    var body: some View {
        let all = TeXDiagnostics.displayed(project.diagnostics)
        let grouped = Dictionary(grouping: all, by: \.severity)
        let entries = tab.severity.map { grouped[$0] ?? [] } ?? all
        let firstErrorID = TeXDiagnostics.primaryError(all)?.id
        VStack(spacing: 0) {
            if project.setupIssue != nil || !TeXConfiguration.current.missingTools(buffers: project.buffers).isEmpty {
                HStack {
                    Spacer()
                    Button("TeX setup") { project.setupNeeded = true }.remileHelp("View missing tools and packages")
                }.padding(.horizontal, 10).padding(.top, 8)
            }
            if project.pdf != nil && !project.outputCurrent && !project.compiling && !project.log.isEmpty {
                Text("Previous build · recompile changes").font(RemileType.caption).foregroundStyle(RemileStyle.warning).padding(.top, 8)
            }
            if project.submissionCheck {
                Text("LaTeX only · 3 passes · no .bib/.bbl or BibTeX/Biber").font(RemileType.small).foregroundStyle(.secondary).padding(.top, 10)
            }
            filters(total: all.count, grouped: grouped).padding(10)
            Divider()
            if tab == .terminal {
                ScrollView {
                    Text(project.log.isEmpty ? "No compilation yet" : project.log)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if entries.isEmpty {
                            Text(project.compiling ? "Compiling…" : project.log.isEmpty ? "No compilation yet" : tab.emptyMessage)
                                .foregroundStyle(.secondary).padding(16)
                        }
                        ForEach(entries) { entry in
                            TeXDiagnosticRow(project: project, entry: entry, checkFirst: entry.id == firstErrorID)
                        }
                    }.padding(10)
                }
            }
        }.font(RemileType.control).background(RemileStyle.sidebar)
            .onAppear { if project.compileFailed { tab = .errors } }
            .onChange(of: project.compileFailed) { if project.compileFailed { tab = .errors } }
    }

    private func filters(total: Int, grouped: [TeXDiagnostic.Severity: [TeXDiagnostic]]) -> some View {
        let label: (Tab) -> String = { item in
            guard item != .terminal else { return item.rawValue }
            let count = item.severity.map { grouped[$0]?.count ?? 0 } ?? total
            return "\(item.rawValue) \(count)"
        }
        return ViewThatFits(in: .horizontal) {
            RemileSegmentedControl(title: "Build output", selection: $tab, options: Tab.allCases, label: label)
                .frame(minWidth: 380)
            Picker("Build output", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { item in Text(label(item)).tag(item) }
            }.labelsHidden()
        }
    }
}

private struct TeXDiagnosticRow: View {
    @ObservedObject var project: TeXProject
    let entry: TeXDiagnostic
    let checkFirst: Bool
    @ObservedObject private var usage = AIUsage.shared
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @State private var showingAdvice = false

    private var symbol: String {
        switch entry.severity {
        case .error: "xmark.octagon"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    var body: some View {
        let location = project.diagnosticLocation(entry, allowFileOnly: true)
        let jumpLabel = entry.line == nil ? "Open source file" : "Go to source"
        HStack(spacing: RemileControl.spacing) {
            summary(file: location?.file)
                .accessibilityElement(children: .combine)
            if location != nil {
                Button { project.reveal(entry) } label: {
                    SymbolIcon(systemName: "scope").foregroundStyle(RemileStyle.ink)
                }.buttonStyle(RemileToolStyle()).accessibilityLabel(jumpLabel).remileHelp(jumpLabel)
            }
            if entry.severity != .info && !entry.isBuildSummary {
                Button { showingAdvice = true } label: {
                    GPTMark().frame(width: RemileControl.iconSlot, height: RemileControl.iconSlot)
                }.buttonStyle(RemileToolStyle()).accessibilityLabel("Suggest a fix with ChatGPT")
                    .disabled(project.compiling || usage.active || usage.reason != nil || provider == "Off")
                    .remileHelp(provider == "Off" ? "AI off" : usage.reason ?? "Suggest a fix with ChatGPT")
                    .popover(isPresented: $showingAdvice, arrowEdge: .leading) { TeXChatGPTReview(project: project, diagnostic: entry) }
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
    }

    private func summary(file: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SymbolIcon(systemName: symbol).foregroundStyle(entry.severity == .info ? RemileStyle.secondaryInk : RemileStyle.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if checkFirst { Text("Check first").font(RemileType.caption.weight(.semibold)).foregroundStyle(RemileStyle.accent) }
                Text(entry.displayMessage).font(RemileType.callout).fixedSize(horizontal: false, vertical: true)
                if let file = file ?? entry.file.map({ ($0 as NSString).lastPathComponent }) {
                    Text(file + (entry.line.map { ":\($0)" } ?? ""))
                        .font(RemileType.small).foregroundStyle(RemileStyle.secondaryInk)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
