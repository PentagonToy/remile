import XCTest

@testable import Remile

final class CLIArgumentTests: XCTestCase {
    private let sourceSHA256 = String(repeating: "a", count: 64)
    private let target = UUID().uuidString
    private let overleafID = "0123456789abcdef01234567"

    private func accepts(
        _ command: String, _ options: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNoThrow(
            try EditorCLIArguments.validate(command: command, options: options), "\(command) \(options)", file: file,
            line: line)
    }

    private func rejects(_ command: String, _ options: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try EditorCLIArguments.validate(command: command, options: options), "\(command) \(options)", file: file,
            line: line)
    }

    func testRangesAndPaths() {
        // A malformed range must never become an unrestricted edit of the active document.
        accepts(
            "transform",
            ["--action", "indent", "--start", "0", "--length", "12", "--apply", "--expected-sha256", sourceSHA256])
        rejects("transform", ["--action", "indent", "--start", "oops", "--apply", "--expected-sha256", sourceSHA256])
        rejects("transform", ["--action", "indent", "--start", "0", "--length", "oops"])
        rejects("transform", ["--length", "12"])
        rejects("transform", ["--start", "-1"])
        rejects("transform", ["--start", String(Int.max), "--length", "1"])
        rejects("replace", ["--source-file", "/tmp/source", "--expected-sha256", "bad-hash"])
        rejects("replace", ["--source-file", "--expected-sha256", sourceSHA256])
        rejects("replace", ["--file", "one.tex", "--file", "two.tex"])
        rejects("save", ["--fiel", "main.tex"])
        rejects("compile", ["--scratch", "--scratch"])
        rejects("logs", ["--tail", "oops"])
        rejects("logs", ["--tail", "0"])
        rejects("pdf-read", ["--page", "0"])
        rejects("pdf-read", ["--page"])
        rejects("pdf-read", ["--page", "9999999999999999999999999"])
        rejects("pdf-read", ["--page", "1", "/tmp/one.pdf"])
        rejects("comments", ["relative.pdf"])
        rejects("open", [])
        rejects("open", ["/tmp/one", "/tmp/two"])
        rejects("build", ["/tmp/project", "--ouput", "/tmp/output"])
        rejects("library-search", ["--no-boost"])
        rejects("library-search", ["query", "--offset", "-1"])
        rejects("library-search", ["query", "--offset", "9999999999999999999999"])
        rejects("library-search", ["query", "--offset", "x"])
        accepts("library-search", ["query", "--offset", "200", "--no-boost"])
        rejects("library-search", ["question", "--no-bost"])
        rejects("status", ["ignored"])
        rejects("unknown", [])
        accepts("pdf-read", ["/tmp/a file.pdf", "--page", "2", "--find", "a word"])
        accepts("read", ["--file", "contents/a file.tex"])
        accepts("replace", ["--source-file", "/tmp/source", "--expected-sha256", sourceSHA256])
        accepts("library-search", ["a question", "--no-boost"])
        accepts("library-search", ["--no-boost", "a", "question"])
        accepts("combine", ["/tmp/one.pdf", "--output", "/tmp/out.pdf", "/tmp/two.pdf"])
        accepts("build", ["/tmp/project", "--output", "/tmp/result", "--main", "main.tex", "--submission-check"])
        accepts("review", ["/tmp/project", "--format", "json"])
        accepts("review", ["--criteria"])
        accepts("compile", ["--submission-check", "--scratch"])
        accepts("transform", ["--action", "indent", "--start", "0"])
        for command in ["help", "--help", "version", "--version", "doctor", "status", "diagnostics", "save", "history"]
        { accepts(command) }
    }

    func testExplicitTargetsAndRevisions() {
        accepts("documents")
        accepts("read", ["--target", target, "--file", "main.tex"])
        accepts("replace", ["--target", target, "--source-file", "/tmp/source", "--expected-sha256", sourceSHA256])
        rejects("read", ["--target", "invalid"])
        rejects("documents", ["--target", target])
        accepts("reference", ["import", "--library", target, "--source-file", "/tmp/input.bib"])
        accepts(
            "reference", ["update", "--id", target, "--expected-revision", target, "--source-file", "/tmp/input.bib"])
        rejects("reference", ["update", "--id", target, "--source-file", "/tmp/input.bib"])
        rejects("reference", ["trash", "--id", target])
        rejects("reference", ["import", "--library", target, "--source-file", "relative.bib"])
    }

    func testAmbiguousTargets() {
        for command in ["review", "pdf-read", "comments"] {
            accepts(command, ["--target", target])
            rejects(command, ["/tmp/project", "--target", target])
        }
    }

    func testWriterViewAndCollect() {
        accepts("writer-view", ["--zoom", "1.25", "--rulers", "on", "--target", target])
        accepts("writer-view", ["--fit"])
        rejects("writer-view", ["--zoom", "nan"])
        rejects("writer-view", ["--zoom", "0"])
        rejects("writer-view", ["--zoom", "1", "--fit"])
        rejects("writer-view", ["--rulers", "maybe"])
        accepts("reference", ["collect", "--library", target, "--source-file", "/tmp/fixture.pdf"])
        rejects("reference", ["collect", "--source-file", "/tmp/fixture.pdf"])
    }

    func testWriterPageAndObjects() {
        accepts("writer-page", ["--header", "A letter", "--top-line", "on", "--expected-sha256", sourceSHA256])
        accepts("writer-page", ["--clear-footer", "--expected-sha256", sourceSHA256])
        rejects("writer-page", ["--page-numbers", "on"])
        rejects("writer-page", ["--header", "Text", "--clear-header", "--expected-sha256", sourceSHA256])
        accepts("writer-object", ["--id", target, "--wrap", "on", "--lock", "off", "--expected-sha256", sourceSHA256])
        rejects("writer-object", ["--id", target, "--wrap", "on"])
        rejects("writer-object", ["--id", "bad"])
    }

    func testWriterColumns() {
        accepts("writer-page", ["--columns", "2", "--expected-sha256", sourceSHA256])
        rejects("writer-page", ["--columns", "3", "--expected-sha256", sourceSHA256])
        rejects("writer-page", ["--columns", "2"])
    }

    func testOverleafReferences() {
        accepts("overleaf", ["list", "--query", "sample"])
        accepts("overleaf", ["show", "--id", "overleaf:" + overleafID])
        accepts("overleaf", ["open", "--id", overleafID, "--connection", target])
        accepts("overleaf", ["read", "--id", overleafID, "--target", target, "--file", "main.tex"])
        accepts("overleaf", ["review", "--id", overleafID, "--format", "markdown", "--output", "/tmp/review.md"])
        accepts("overleaf", ["review", "--id", overleafID, "--format", "bundle", "--output", "/tmp/review.zip"])
        rejects("overleaf", ["review", "--id", overleafID, "--format", "bundle"])
        rejects("overleaf", ["review", "--id", overleafID, "--format", "html"])
        rejects("overleaf", ["review", "--id", overleafID, "--output", "relative.json"])
        rejects("overleaf", ["show"])
        rejects("overleaf", ["show", "--id", "../projects"])
        rejects("overleaf", ["list", "--id", overleafID])
        rejects("overleaf", ["read", "--id", overleafID])
        rejects("overleaf", ["open", "--id", overleafID, "--connection", "bad"])
        rejects("overleaf", ["delete", "--id", overleafID])
        rejects("overleaf", ["read", "--id", overleafID, "--target", "bad", "--file", "main.tex"])
        XCTAssertTrue(OverleafProjectID.parse("overleaf:0123456789ABCDEF01234567") == overleafID)
        XCTAssertTrue(OverleafProjectID.parse("overleaf:" + overleafID + "\n") == nil)
        XCTAssertTrue(OverleafProjectID.parse("overleaf:0123456789abcdef0123456g") == nil)
        XCTAssertTrue(OverleafProjectID.parse(OverleafProjectID.reference(overleafID)) == overleafID)
    }

    func testPDFRegions() {
        accepts("pdf-regions", ["/tmp/paper.pdf", "--page", "4"])
        accepts(
            "pdf-regions",
            [
                "/tmp/paper.pdf", "--tables", "--region", "table-1", "--output", "/tmp/table.tsv", "--expected-sha256",
                sourceSHA256,
            ])
        rejects("pdf-regions", [])
        rejects("pdf-regions", ["relative.pdf"])
        rejects("pdf-regions", ["/tmp/paper.pdf", "--page", "0"])
        rejects("pdf-regions", ["/tmp/paper.pdf", "--target", target])
    }

    func testRecognitionAndDraftSaving() {
        accepts("reference", ["recognise", "--id", UUID().uuidString, "--expected-revision", UUID().uuidString])
        rejects("reference", ["recognise", "--id", UUID().uuidString])
        accepts("save", ["--output", "/tmp/new-project"])
    }
}
