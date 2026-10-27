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
    func start(root: URL, main: String, buffers: [String: String], completion: @escaping () -> Void) {
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
                    try TeXSubmissionComparison.run(root: root, main: main, buffers: buffers, configuration: configuration, output: output, job: job, progress: publish)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submission check").font(RemileType.heading)
            ForEach(0..<2, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    if ["waiting", "running"].contains(check.rows[index].state) { ProgressView().controlSize(.small).opacity(check.rows[index].state == "waiting" ? 0.4 : 1) }
                    else { SymbolIcon(systemName: check.rows[index].state == "passed" ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(check.rows[index].state == "passed" ? Color.green : RemileStyle.accent) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(index == 0 ? "Current source" : "With bibliography embedded").font(RemileType.callout.weight(.semibold))
                        Text(check.rows[index].detail).font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let path = check.rows[index].logPath { Button("Log") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.font(RemileType.caption) }
                }
            }
            if check.buffers != project.buffers || check.main != project.main { Text("Source changed. Run the check again.").font(RemileType.caption).foregroundStyle(.secondary) }
            Text("Fresh LaTeX passes without external bibliography files. Uses your installed engine. Your source stays unchanged.").font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if check.running { Button("Stop") { check.stop() } }
                else { Button("Check again") { project.compareSubmission() } }
                Spacer()
                Button("Done") { project.showsSubmission = false }
            }
        }.padding(20).frame(width: 390).background(RemileStyle.background)
    }
}
