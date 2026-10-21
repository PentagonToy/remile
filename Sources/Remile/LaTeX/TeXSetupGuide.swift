import SwiftUI

struct TeXSetupGuide: View {
    let missing: [String]
    var issue: TeXSetupIssue? = nil
    var directory = TeXConfiguration.current.directory
    var resolution: TeXPackageResolution? = nil
    @StateObject private var lookup = Lookup()
    @MainActor private final class Lookup: ObservableObject {
        @Published var running = false
        @Published var result: TeXPackageResolution?
        @Published var attempt = 0
        func load(_ files: [String], directory: String) async {
            running = true; result = nil
            let response = await TeXPackageResolver.shared.resolve(files: files, directory: directory)
            guard !Task.isCancelled else { return }
            result = response; running = false
        }
    }
    private var resolved: TeXPackageResolution? { resolution ?? lookup.result }
    private var commands: [String] { issue?.commands(directory: directory, resolution: resolved) ?? [] }
    private var missingDescription: String {
        guard let issue else { return "" }
        if !issue.files.isEmpty { return issue.files.joined(separator: ", ") }
        return issue.managerNeedsUpdate ? "Update TeX Live Manager." : "Ghostscript is needed for EPS graphics."
    }
    private var unknown: [String] { (issue?.files ?? []).filter { resolved?.owners[$0]?.isEmpty != false } }
    private var ambiguous: [String] { (issue?.files ?? []).filter { (resolved?.owners[$0]?.count ?? 0) > 1 } }
    @ViewBuilder private var lookupStatus: some View {
        if lookup.running { HStack { ProgressView().controlSize(.small); Text("Finding required packages…").font(RemileType.caption) } }
        else if let resolved {
            if let notice = resolved.notice {
                Text(notice).font(RemileType.caption).foregroundStyle(RemileStyle.warning)
                Button("Retry package lookup") { lookup.attempt += 1 }
            }
            if !unknown.isEmpty && resolved.notice == nil { Text("Not found in TeX Live: " + unknown.joined(separator: ", ") + ". Check project files.").font(RemileType.caption) }
            if !ambiguous.isEmpty { Text("Multiple packages match: " + ambiguous.joined(separator: ", ") + ". Review the search results.").font(RemileType.caption) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(issue == nil ? "LaTeX is not ready" : "Missing TeX dependencies").font(RemileType.heading)
            if issue != nil {
                Text(missingDescription)
                    .font(RemileType.callout).foregroundStyle(.secondary).textSelection(.enabled)
                lookupStatus
            } else {
                if !missing.isEmpty { Text("Missing tools: " + missing.joined(separator: ", ")).font(RemileType.caption).foregroundStyle(.secondary) }
                Text("Choose your existing TeX folder in Project settings, or install the missing tools with TeX Live Manager.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !lookup.running { ForEach(commands, id: \.self) { TeXGuidanceCommand(command: $0) } }
            Link("TeX installation help", destination: URL(string: "https://www.tug.org/mactex/morepackages.html")!).font(.callout)
        }.padding(20).frame(width: 490).background(RemileStyle.background)
            .task(id: (issue?.files.joined(separator: "|") ?? "") + directory + String(lookup.attempt)) {
                guard resolution == nil, let files = issue?.files, !files.isEmpty else { return }
                await lookup.load(files, directory: directory)
            }
    }
}

struct TeXGuidanceCommand: View {
    let command: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 32, height: 32).contentShape(Rectangle()) }
                .buttonStyle(RemileToolStyle()).remileHelp("Copy command").accessibilityLabel("Copy command")
        }.padding(10).overlay(RoundedRectangle(cornerRadius: RemileRadius.control).stroke(RemileStyle.ink.opacity(0.15)))
    }
}

struct TeXCompileGuidance: View {
    @ObservedObject var project: TeXProject
    let showDiagnostics: () -> Void
    var resolution: TeXPackageResolution? = nil
    @StateObject private var layout = Layout()
    private final class Layout: ObservableObject { @Published var height: CGFloat = 280 }
    private var missing: [String] { TeXConfiguration.current.missingTools(buffers: project.buffers) }
    private var report: TeXBuildReport { TeXBuildReport(log: project.log, diagnostics: project.diagnostics, missingTools: missing) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            if report.issue != nil || !missing.isEmpty {
                TeXSetupGuide(missing: missing, issue: report.issue, resolution: resolution)
            }
                VStack(alignment: .leading, spacing: 12) {
                    if report.problems.isEmpty { Text(project.message ?? "Open the compiler log for details.").font(RemileType.callout) }
                    ForEach(report.problems.filter { $0.category == .source || $0.category == .compiler }) { problem in
                        Text(problem.category.rawValue).font(RemileType.caption).foregroundStyle(.secondary)
                        Text(problem.message).font(RemileType.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let entry = problem.diagnostic, let file = entry.file {
                        Button(file + (entry.line.map { ":\($0)" } ?? "")) { project.setupNeeded = false; project.reveal(entry) }
                            .font(RemileType.caption).remileHelp("Show source")
                        }
                    }
                    Text("More errors may appear after recompiling.").font(RemileType.caption).foregroundStyle(.secondary)
                    TeXDiagnosticAdviceView(project: project)
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in Color.clear.preference(key: TeXGuidanceHeight.self, value: geometry.size.height) })
            }.frame(height: min(480, max(80, layout.height)))
                .onPreferenceChange(TeXGuidanceHeight.self) { if abs(layout.height - $0) > 1 { layout.height = $0 } }
            HStack { Spacer(); Button("View diagnostics", action: showDiagnostics) }
                .padding(.horizontal, 20).padding(.bottom, 16)
        }.frame(width: 490, alignment: .leading).foregroundStyle(RemileStyle.ink).background(RemileStyle.background)
    }
}

private struct TeXGuidanceHeight: PreferenceKey {
    static var defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


struct TeXEnvironmentResult: View {
    let report: TeXEnvironmentReport?
    let directory: String
    var resolution: TeXPackageResolution? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report {
                if !report.missingTools.isEmpty {
                    TeXSetupGuide(missing: report.missingTools, directory: directory)
                } else if let issue = report.issue {
                    TeXSetupGuide(missing: [], issue: issue, directory: directory, resolution: resolution)
                } else {
                    Label(report.ready ? (report.projectChecked ? "LaTeX checks passed" : "Basic TeX tools available") : "Check incomplete", systemImage: report.ready ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(RemileType.heading)
                }
                Text(report.projectChecked ? "Checked tools and \(report.checkedFiles) declared files. Compile to verify fonts and other dependencies." : "Basic tools checked. Open a LaTeX project to check its dependencies.")
                    .font(RemileType.caption).foregroundStyle(.secondary)
                if !report.unverifiedFiles.isEmpty {
                    Text("Could not verify: " + report.unverifiedFiles.joined(separator: ", ")).font(RemileType.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking LaTeX environment…") }
            }
        }.padding(18).frame(width: 530, alignment: .leading).background(RemileStyle.background)
    }
}
