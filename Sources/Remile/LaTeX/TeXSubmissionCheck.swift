import SwiftUI

@MainActor final class TeXSubmissionCheck: ObservableObject {
    @Published var rows = [TeXSubmissionComparison.Row(), TeXSubmissionComparison.Row()]
    @Published private(set) var running = false
    private(set) var buffers: [String: String] = [:]
    private(set) var main = ""
    private(set) var embedded: String?
    private var cachedOutput: URL?
    private var job: TeXCompileJob?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(root: URL, main: String, buffers: [String: String], compareEmbedded: Bool, completion: @escaping () -> Void) {
        guard !running else { return }
        self.buffers = buffers; self.main = main; embedded = nil
        rows = [.init(), .init()]; running = true
        let generation = UUID(); self.generation = generation
        let job = TeXCompileJob(); self.job = job
        let configuration = TeXConfiguration.current
        TeXCache.discard(cachedOutput)
        let output = TeXCache.allocate("Submission"); cachedOutput = output
        let publish: @Sendable (Int, TeXSubmissionComparison.Row) -> Void = { [weak self] index, row in
            Task { @MainActor [weak self] in guard let self, self.generation == generation, self.running else { return }; self.rows[index] = row }
        }
        task = Task { @MainActor [weak self] in
            let owner = self; defer { withExtendedLifetime(owner) { } }
            do {
                let result = try await Task.detached {
                    try TeXSubmissionComparison.run(root: root, main: main, buffers: buffers, configuration: configuration,
                                                    output: output, job: job, compareEmbedded: compareEmbedded, progress: publish)
                }.value
                guard let self, self.generation == generation else { return }; self.rows = result.rows; self.embedded = result.embedded
            } catch {
                if let self { for index in self.rows.indices where ["waiting", "running"].contains(self.rows[index].state) { self.rows[index] = .init(state: "failed", detail: error is CancellationError ? "Stopped" : error.localizedDescription) } }
            }
            self?.running = false; self?.job = nil; completion()
        }
    }
    deinit { TeXCache.discard(cachedOutput) }
    func stop() { job?.stop() }
    var json: [[String: Any]] { rows.enumerated().map { index, row in
        ["kind": index == 0 ? "current" : "embedded", "state": row.state, "detail": row.detail, "log": row.log, "logPath": row.logPath ?? "", "pdf": row.pdf ?? ""]
    } }
}

struct TeXSubmissionPopover: View {
    @ObservedObject var project: TeXProject
    @ObservedObject var check: TeXSubmissionCheck
    private var result: TeXSubmissionComparison.Row { check.rows[0] }
    private var sourceChanged: Bool { check.buffers != project.buffers || check.main != project.main }

    var body: some View {
        let diagnostic = result.issue == .compiler ? TeXDiagnostics.primaryError(TeXDiagnostics.parse(result.log)) : nil
        let source = result.logPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("Source") }
        let location = diagnostic.flatMap { project.diagnosticLocation($0, snapshot: source) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Submission check").font(RemileType.heading)
            if check.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking source…")
                }
            } else if sourceChanged {
                Text("Source changed. Check again.")
            } else if result.state == "passed" {
                SymbolLabel(result.detail, systemImage: "checkmark.circle.fill")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(diagnostic.map { String($0.message.prefix(260)) } ?? result.detail)
                    if let location {
                        Text("\(location.file):\(location.line + 1)").font(RemileType.caption).foregroundStyle(.secondary)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if check.running { Button("Stop") { check.stop() } }
                else if sourceChanged || result.detail == "Stopped" {
                    Button("Check again") { project.compareSubmission(compareEmbedded: false) }
                } else if result.state != "passed", let path = result.logPath {
                    Button("View log") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                Spacer()
                Button("Done") { project.showsSubmission = false }.keyboardShortcut(.cancelAction)
                if !check.running, !sourceChanged {
                    if let location {
                        Button("Go to source") {
                            project.showsSubmission = false
                            project.visit(file: location.file, line: location.line)
                        }.buttonStyle(RemileActionStyle(emphasis: .primary))
                    }
                }
            }
        }.padding(20).frame(width: 380).background(RemileStyle.background)
    }
}
