import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
var passed = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); passed += 1; print("PASS: " + message) }
func refuses(_ message: String, _ action: () throws -> Void) { do { try action(); fatalError(message) } catch { check(true, message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() { precondition(ContinuousClock.now < deadline, "Review fixture timed out"); try await Task.sleep(for: .milliseconds(10)) }
}
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("manuscript"), storage = output.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "\\documentclass{article}\n\\begin{document}\nWe claim stable performance across settings.\nValidation used one workload.\nReport count: 41.\nTable count: 38.\n\\end{document}\n"
        let buffers = ["main.tex": source]
        try source.write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let catalog = try ReviewCatalog.load(), context = try ReviewContext.make(buffers: buffers, selected: "main.tex", budget: 8000)
        check(catalog.criteria.count == 6 && catalog.criteria.allSatisfy { $0.example.synthetic && !$0.suppressWhen.isEmpty }, "Every criterion has a synthetic scenario and an explicit false-positive exception")
        let catalogueText = String(decoding: try ReviewCatalog.resource("criteria.json"), as: UTF8.self)
        check(catalogueText.range(of: #"https?://|10\.\d{4,}/|[\w.+-]+@[\w.-]+|Reviewer\s+\d"#, options: .regularExpression) == nil, "Bundled cases contain no source URLs, DOIs, email addresses or reviewer identities")
        check(try ReviewCatalog.instructions().contains("untrusted data"), "Question instructions keep manuscript data outside the instruction boundary")
        func response(criterion: String = "scope", question: String = "Would naming the tested workload make the scope clearer?", quotes: [String] = ["We claim stable performance across settings.", "Validation used one workload."]) throws -> String {
            let obj: [String: Any] = ["findings": [["criterion": criterion, "question": question, "reason": "The claim spans settings while the supplied validation describes one workload.", "anchors": quotes.map { ["file": "main.tex", "quote": $0] }]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let reply = try response(), questions = try context.questions(from: reply, catalog: catalog)
        check(questions.count == 1 && questions[0].anchors[0].line == 2 && questions[0].anchors[0].sourceSHA256 == EditorBridge.digest(source), "A question links to the exact reviewed file, line and version")
        refuses("A missing quoted passage cannot become a saved finding") { _ = try context.questions(from: response(quotes: ["Not in this manuscript."]), catalog: catalog) }
        refuses("An unknown criterion is refused") { _ = try context.questions(from: response(criterion: "invented"), catalog: catalog) }
        refuses("A verdict without a question is refused") { _ = try context.questions(from: response(question: "This manuscript is inadequate."), catalog: catalog) }
        refuses("A numerical comparison requires two distinct passages") { _ = try context.questions(from: response(criterion: "consistency", quotes: ["Report count: 41."]), catalog: catalog) }
        refuses("Repeating one anchor cannot establish redundancy") { _ = try context.questions(from: response(criterion: "clarity", quotes: ["Report count: 41.", "Report count: 41."]), catalog: catalog) }
        let consistency = try context.questions(from: response(criterion: "consistency", quotes: ["Report count: 41.", "Table count: 38."]), catalog: catalog)
        check(consistency[0].anchors.count == 2, "A consistency question retains both locations for the author to inspect")
        let small = try ReviewContext.make(buffers: ["main.tex": String(repeating: "🧪", count: 1000), "other.tex": "Other source"], selected: "main.tex", budget: 180)
        check(small.documents.values.reduce(0) { $0 + $1.utf8.count } <= 180 && small.truncated.contains("main.tex"), "Context is byte bounded without splitting Unicode and reports truncation")
        let compactRequest = try JSONSerialization.jsonObject(with: Data(small.request(catalog: catalog, compact: true).utf8)) as! [String: Any]
        check(compactRequest["maximumFindings"] as? Int == 2, "Compact model requests limit question count to fit the response budget")
        check(context.fingerprint(criteria: "template-a", provider: "Fixture") != context.fingerprint(criteria: "template-b", provider: "Fixture"), "Template changes invalidate reuse for the same manuscript version")
        refuses("An empty source is not represented as a completed review") { _ = try ReviewContext.make(buffers: ["main.tex": ""], selected: "main.tex", budget: 1000) }
        var calls = 0
        let engine = AssistantEngine(status: { (true, "Fixture") }, expandedContext: true, respond: { request, instructions, tokens in
            calls += 1
            check(request.contains("documents") && request.contains("criteria") && tokens <= 3200, "The explicit review request supplies bounded manuscript context and criteria")
            return reply
        })
        let store = ManuscriptReviewStore.shared(for: root, directory: storage)
        try store.start(buffers: buffers, selected: "main.tex", engine: engine, provider: "Fixture")
        try await until { !store.running }
        check(store.message == nil && store.archive.runs.count == 1, "A completed grounded response is persisted")
        let archiveFile = ManuscriptReviewStore.file(for: root, under: storage)
        check(try (FileManager.default.attributesOfItem(atPath: archiveFile.path)[.posixPermissions] as? Int) == 0o600, "Saved manuscript questions have private file permissions")
        let reopened = ManuscriptReviewStore(root: root, directory: storage)
        check(reopened.archive.runs.first?.id == store.archive.runs.first?.id, "Reopening a project preserves the same saved questions")
        try store.start(buffers: buffers, selected: "main.tex", engine: engine, provider: "Fixture")
        check(!store.running && calls == 1 && store.archive.runs.count == 1, "An unchanged version reuses its review instead of sending another model request")
        var changed = buffers; changed["main.tex"]! += "% additional context\n"
        try store.start(buffers: changed, selected: "main.tex", engine: engine, provider: "Fixture"); try await until { !store.running }
        check(store.archive.runs.count == 2 && store.archive.runs[0].questions[0].id == reopened.archive.runs[0].questions[0].id, "A new version appends a review instead of replacing historical questions")
        check(store.archive.runs[0].sourceHashes["main.tex"] == EditorBridge.digest(source) && store.archive.runs[1].sourceHashes["main.tex"] == EditorBridge.digest(changed["main.tex"]!), "Historical versions retain separate evidence hashes")
        let beforeBad = try Data(contentsOf: archiveFile)
        let bad = AssistantEngine(status: { (true, "Fixture") }, expandedContext: true, respond: { _,_,_ in "{\"findings\":[{\"made_up\":true}]}" })
        var changedAgain = changed; changedAgain["main.tex"]! += "% more\n"
        try store.start(buffers: changedAgain, selected: "main.tex", engine: bad, provider: "Fixture"); try await until { !store.running }
        check(try Data(contentsOf: archiveFile) == beforeBad && store.message != nil, "Malformed responses leave the persisted archive unchanged")
        let jsonFile = output.appendingPathComponent("questions.json"), mdFile = output.appendingPathComponent("questions.md")
        _ = try store.response(format: .json, output: jsonFile.path); _ = try store.response(format: .markdown, output: mdFile.path)
        check(try ReviewArchive.decoder().decode(ReviewArchive.self, from: Data(contentsOf: jsonFile)).runs.count == 2, "JSON export contains reusable questions and versioned evidence")
        check(try String(contentsOf: mdFile, encoding: .utf8).contains("SHA256"), "Markdown export includes readable questions and source provenance")
        refuses("CLI-style exports never overwrite an existing destination") { _ = try store.response(format: .json, output: jsonFile.path) }
        check(try ManuscriptReviewCommands.criteria()["ok"] as? Bool == true, "CLI criteria access is available without starting a review")
        let missingProject = ManuscriptReviewCommands.handle(.init(operation: "review"), project: nil)
        check(missingProject["ok"] as? Bool == false, "A live review without a project fails explicitly")
        let noQuestions = AssistantEngine(status: { (true, "Fixture") }, respond: { _,_,_ in "{\"findings\":[]}" })
        let emptyStore = ManuscriptReviewStore(root: output.appendingPathComponent("empty"), directory: storage)
        try emptyStore.start(buffers: buffers, selected: "main.tex", engine: noQuestions, provider: "Fixture"); try await until { !emptyStore.running }
        check(emptyStore.archive.runs.count == 1 && emptyStore.archive.runs[0].questions.isEmpty && !emptyStore.archive.runs[0].scope.isEmpty, "An empty result records scope without claiming that the manuscript is error free")
        let project = try TeXProject(root, historyEnabled: false)
        for dark in [true, false] {
            let host = NSHostingView(rootView: ManuscriptReviewPanel(project: project, store: store).environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host; window.orderFront(nil)
            await Task.yield(); host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "review-dark.png" : "review-light.png")) }
            window.orderOut(nil)
        }
        let destination = output.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: root, to: destination)
        try store.relocate(to: destination)
        check(try ManuscriptReviewStore.read(root: destination, directory: storage).runs.count == 2 && !FileManager.default.fileExists(atPath: archiveFile.path), "Project rename retains review history under the new identity")
        var held: CheckedContinuation<String, Never>?
        let heldEngine = AssistantEngine(status: { (true, "Fixture") }, expandedContext: true, respond: { _,_,_ in await withCheckedContinuation { held = $0 } })
        try store.start(buffers: changedAgain, selected: "main.tex", engine: heldEngine, provider: "Held")
        try await until { held != nil }
        try store.clear(); held!.resume(returning: reply)
        await Task.yield(); await Task.yield()
        check(store.archive.runs.isEmpty && !store.running && !FileManager.default.fileExists(atPath: ManuscriptReviewStore.file(for: destination, under: storage).path), "Clear cancels work and a late model reply cannot restore erased questions")
        try store.start(buffers: buffers, selected: "main.tex", engine: engine, provider: "Fixture"); try await until { !store.running }
        try ManuscriptReviewStore.remove(root: destination, directory: storage)
        check(store.archive.runs.isEmpty && !store.hasSavedData, "Library removal clears both disk results and the active shared store")
        let child = ManuscriptReviewStore.shared(for: destination.appendingPathComponent("child"), directory: storage)
        let neighbour = ManuscriptReviewStore.shared(for: URL(fileURLWithPath: destination.path + "-other"), directory: storage)
        for value in [child, neighbour] { try value.start(buffers: buffers, selected: "main.tex", engine: engine, provider: "Fixture"); try await until { !value.running } }
        try ManuscriptReviewStore.removeLibraryFolder(destination, directory: storage)
        check(!child.hasSavedData && neighbour.hasSavedData, "Removing a library folder clears descendant reviews and preserves similarly named neighbours")
        try neighbour.clear()
        let corruptRoot = output.appendingPathComponent("corrupt"), corrupt = ManuscriptReviewStore.file(for: corruptRoot, under: storage)
        try Data("broken".utf8).write(to: corrupt)
        let broken = ManuscriptReviewStore(root: corruptRoot, directory: storage)
        refuses("Unreadable archives cannot be silently replaced by a new review") { try broken.start(buffers: buffers, selected: "main.tex", engine: engine) }
        check(try Data(contentsOf: corrupt) == Data("broken".utf8), "An unreadable saved archive stays recoverable")
        try broken.clear(); check(!broken.hasSavedData, "Explicit Clear can recover from an unreadable archive")
        print("Passed \(passed) manuscript review checks")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
