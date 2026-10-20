import Foundation

/// Two isolated builds of one captured revision; neither changes the editor or project files.
enum TeXSubmissionComparison {
    struct Row: Codable, Sendable {
        var state = "waiting"
        var detail = "Waiting"
        var log = ""
        var logPath: String? = nil
        var pdf: String? = nil
    }
    struct Result: Sendable { let rows: [Row]; let embedded: String? }
    static func run(root: URL, main: String, buffers: [String: String], configuration: TeXConfiguration, output: URL, job: TeXCompileJob, progress: @escaping @Sendable (Int, Row) -> Void = { _, _ in }) throws -> Result {
        func checked(_ result: TeXCompileJob.Result, directory: String) -> Row {
            Row(state: result.success ? "passed" : "failed", detail: result.success ? "Passed" : "Failed — see log", log: result.log, logPath: output.appendingPathComponent(directory + "/compiler.log").path, pdf: result.success ? result.output.path : nil)
        }
        progress(0, Row(state: "running", detail: "Checking current source…"))
        let current = try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: output.appendingPathComponent("Current"), submissionCheck: true)
        let first = checked(current, directory: "Current"); progress(0, first)
        guard let source = buffers[main] else { throw CocoaError(.fileReadUnknown) }
        let probe = "\\begin{thebibliography}{1}\n\\end{thebibliography}"
        do { _ = try TeXSourceTools.inlineBibliography(source, bbl: probe) }
        catch {
            let second = current.success ? Row(state: "passed", detail: "Passed — no embedding needed", log: current.log, logPath: first.logPath, pdf: first.pdf) : Row(state: "unavailable", detail: error.localizedDescription)
            progress(1, second); return Result(rows: [first, second], embedded: nil)
        }
        progress(1, Row(state: "running", detail: "Preparing bibliography…"))
        var normalConfiguration = configuration; normalConfiguration.bibliography = true
        let normal = try job.run(root: root, main: main, buffers: buffers, configuration: normalConfiguration, output: output.appendingPathComponent("Prepare"), scratch: true)
        guard normal.success else {
            let second = Row(state: "failed", detail: "Could not prepare bibliography — see log", log: normal.log, logPath: output.appendingPathComponent("Prepare/compiler.log").path)
            progress(1, second); return Result(rows: [first, second], embedded: nil)
        }
        let bbl = normal.output.deletingPathExtension().appendingPathExtension("bbl")
        let embedded: String
        do { embedded = try TeXSourceTools.inlineBibliography(source, bbl: String(contentsOf: bbl, encoding: .utf8)) }
        catch {
            let second = Row(state: "unavailable", detail: error.localizedDescription, log: normal.log, logPath: output.appendingPathComponent("Prepare/compiler.log").path)
            progress(1, second); return Result(rows: [first, second], embedded: nil)
        }
        progress(1, Row(state: "running", detail: "Checking embedded source…"))
        var hypothetical = buffers; hypothetical[main] = embedded
        let result = try job.run(root: root, main: main, buffers: hypothetical, configuration: configuration, output: output.appendingPathComponent("Embedded"), submissionCheck: true)
        let second = checked(result, directory: "Embedded"); progress(1, second)
        return Result(rows: [first, second], embedded: embedded)
    }
}
