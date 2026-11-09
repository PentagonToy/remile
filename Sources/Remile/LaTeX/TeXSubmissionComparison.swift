import Foundation

/// Isolated checks of one captured revision leave the editor and project files untouched.
enum TeXSubmissionComparison {
    struct Row: Codable, Sendable {
        var state = "waiting"
        var detail = "Waiting"
        var log = ""
        var logPath: String? = nil
        var pdf: String? = nil
        var issue: TeXCompileJob.SubmissionIssue? = nil
    }
    struct Result: Sendable { let rows: [Row]; let embedded: String? }
    static func run(root: URL, main: String, buffers: [String: String], configuration: TeXConfiguration, output: URL, job: TeXCompileJob, compareEmbedded: Bool = true, progress: @escaping @Sendable (Int, Row) -> Void = { _, _ in }) throws -> Result {
        func checked(_ result: TeXCompileJob.Result, directory: String, engine: String = "pdfLaTeX") -> Row {
            let detail: String
            switch result.submissionIssue {
            case .compiler: detail = "\(engine) stopped with an error."
            case .bibliography: detail = "The bibliography could not be resolved."
            case .unresolved: detail = "Some citations or cross-references did not resolve."
            case .incomplete: detail = "The check did not produce a complete build."
            case .externalSource: detail = "The build read a file outside the project copy. Use a project-relative path."
            case nil:
                detail = result.usedSuppliedBibliography ? "Compiles with the supplied .bbl." : "Compiles with the current files."
            }
            return Row(state: result.success ? "passed" : "failed", detail: detail, log: result.log,
                       logPath: output.appendingPathComponent(directory + "/compiler.log").path,
                       pdf: result.success ? result.output.path : nil, issue: result.submissionIssue)
        }
        if !compareEmbedded {
            let engine = configuration.resolvedEngine(buffers: buffers, submissionCheck: false).rawValue
            progress(0, Row(state: "running", detail: "Checking current source…"))
            let current = try job.run(root: root, main: main, buffers: buffers, configuration: configuration,
                                      output: output.appendingPathComponent("Current"), checkProject: true)
            return Result(rows: [checked(current, directory: "Current", engine: engine),
                                 Row(state: "skipped", detail: "Checked current project files.")], embedded: nil)
        }
        guard configuration.missingTools(buffers: buffers, submissionCheck: true).isEmpty else {
            throw TeXFileSystem.Failure(errorDescription: "pdfLaTeX is unavailable. Check the TeX folder in Settings.")
        }
        progress(0, Row(state: "running", detail: "Checking current source…"))
        let current = try job.run(root: root, main: main, buffers: buffers, configuration: configuration, output: output.appendingPathComponent("Current"), submissionCheck: true)
        let first = checked(current, directory: "Current")
        guard let source = buffers[main] else { throw CocoaError(.fileReadUnknown) }
        let probe = "\\begin{thebibliography}{1}\n\\end{thebibliography}"
        var embeddingError: Error?
        do { _ = try TeXSourceTools.inlineBibliography(source, bbl: probe) }
        catch { embeddingError = error }
        progress(0, first)
        if let embeddingError {
            let second = current.success ? Row(state: "passed", detail: "Passed — no embedding needed", log: current.log, logPath: first.logPath, pdf: first.pdf) : Row(state: "unavailable", detail: embeddingError.localizedDescription)
            progress(1, second); return Result(rows: [first, second], embedded: nil)
        }
        progress(1, Row(state: "running", detail: "Preparing bibliography…"))
        var normalConfiguration = configuration
        normalConfiguration.engine = .pdf
        normalConfiguration.bibliography = true
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
