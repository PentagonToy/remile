import AppKit
import PDFKit
import CoreText

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: " + message); fflush(stdout) }
let atom = """
<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/1706.03762v7</id><published>2017-06-12T17:57:34Z</published><updated>2023-08-02T00:00:00Z</updated><title>Attention Is All You Need</title><summary>Attention &amp; sequence models.</summary><author><name>Ashish Vaswani</name></author><author><name>Łukasz Kaiser</name></author></entry></feed>
"""
Task { @MainActor in
 do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
    let parsed = try ReferenceArxiv.parse(Data(atom.utf8), expectedID: "1706.03762v7")
    check(parsed.year == "2017" && parsed.fields["date"] == "2017-06-12", "Preprint submission year is not the 2023 revision year")
    check(parsed.authors.contains("Łukasz Kaiser") && parsed.fields["abstract"] == "Attention & sequence models.", "Structured authors and abstract preserve Unicode and XML entities")
    check(ReferenceKind.classify(parsed) == .preprint, "Preprints have a readable type")
    for (xml, id) in [(atom, "9999.99999"), (atom.replacingOccurrences(of: "v7", with: "v6"), "1706.03762v7"), ("<feed/>", "1706.03762")] {
        do { _ = try ReferenceArxiv.parse(Data(xml.utf8), expectedID: id); check(false, "Mismatched archive response accepted") } catch { checks += 1 }
    }
    let repository = ReferenceRepository(root: output.appendingPathComponent("Reference"))
    var local = ReferenceRecord(); local.fields = ["title": parsed.title, "eprint": "1706.03762v7", "archiveprefix": "arXiv", "entrysubtype": "preprint"]; local.type = "misc"
    local.attachments = [.init(name: "sample.pdf", sha256: String(repeating: "a", count: 64), bytes: 1)]
    let record = try repository.add([local]).first!
    let enriched = await ReferenceRecognition.enrich([record], repository: repository, lookup: { _ in parsed })[0]
    check(enriched.authors == parsed.authors && enriched.year == "2017", "Identifier enrichment fills missing bibliographic fields")
    check(enriched.id == record.id && enriched.key == record.key && enriched.attachments == record.attachments, "Enrichment keeps identity, citation key and attachments")
    var edited = record; edited.fields["year"] = "2001"; edited.fields["note"] = "My note"
    let combined = try ReferenceRecognition.merged(edited, with: parsed)
    check(combined.year == "2001" && combined.fields["note"] == "My note", "Existing user fields survive enrichment")
    var published = local; published.type = "article"; published.fields["journal"] = "A published journal"; published.fields.removeValue(forKey: "entrysubtype")
    let publishedResult = try ReferenceRecognition.merged(published, with: parsed)
    check(publishedResult.year.isEmpty && ReferenceKind.classify(publishedResult) == .article && publishedResult.authors == parsed.authors, "Preprint lookup cannot relabel a published record or supply its publication date")
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: true], forName: UserDefaults.argumentDomain)
    let offline = await ReferenceRecognition.enrich([record], repository: repository, lookup: { _ in preconditionFailure("Offline lookup was called") })
    check(offline == [record], "Offline import performs no public lookup")
    UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
    var another = local; another.id = UUID()
    let conflict = try repository.add([another]).first!
    _ = await ReferenceRecognition.enrich([conflict], repository: repository, lookup: { current in
        var edit = current; edit.fields["note"] = "Concurrent edit"
        _ = try repository.update(edit, expected: current.revision)
        return parsed
    })
    let retained = try repository.records().first { $0.id == conflict.id }!
    check(retained.fields["note"] == "Concurrent edit" && retained.authors.isEmpty, "Concurrent catalogue edits prevent stale automatic writes")
    let untouchedRoot = try TeXDraft.create(under: output.appendingPathComponent("Drafts"))
    let untouched = try TeXProject(untouchedRoot, draft: true)
    check(!untouched.dirty && untouched.isDraft && untouched.displayName == "Untitled", "A new LaTeX draft opens without a save destination")
    check(untouched.confirmLeaving() && !FileManager.default.fileExists(atPath: untouchedRoot.path), "An untouched draft closes without a save question")
    let draftRoot = try TeXDraft.create(under: output.appendingPathComponent("Drafts"))
    let draft = try TeXProject(draftRoot, draft: true)
    draft.buffers["main.tex"]! += "% Draft edit\n"
    try await Task.sleep(for: .milliseconds(1200))
    let diskDraft = try String(contentsOf: draftRoot.appendingPathComponent("main.tex"), encoding: .utf8)
    check(draft.dirty && diskDraft.contains("Draft edit"), "Working-copy autosave does not make an edited draft appear saved")
    let existing = output.appendingPathComponent("existing"); try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    check(!draft.saveDraft(to: existing) && draft.isDraft, "Saving a draft cannot overwrite an existing folder")
    let destination = output.appendingPathComponent("SavedProject")
    check(draft.saveDraft(to: destination) && !draft.isDraft && !draft.dirty, "Explicit Save promotes the working folder to a normal project")
    check(!FileManager.default.fileExists(atPath: draftRoot.path) && FileManager.default.fileExists(atPath: destination.appendingPathComponent("main.tex").path), "Draft promotion removes only its private working folder")
    draft.releaseWorkspaceResources()
    let source = "A caption describes the Karlovitz number with useful context."
    let offset = (source as NSString).range(of: "number").location
    let hint = TeXSync.hint(in: source, offset: offset)!
    let target = TeXSync.refine(.init(file: "main.tex", line: 0), source: source, hint: hint)
    check(target.range.map { (source as NSString).substring(with: $0) } == "number", "Forward context can identify the selected word rather than a paragraph")
    check(TeXSync.refine(.init(file: "main.tex", line: 0), source: source + "\n" + source, hint: hint).range == nil, "Ambiguous repeated captions keep coarse navigation")
    let queueBytes = NSMutableData(); var queueBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let queueContext = CGContext(consumer: CGDataConsumer(data: queueBytes)!, mediaBox: &queueBox, nil)!
    queueContext.beginPDFPage(nil); queueContext.textPosition = CGPoint(x: 70, y: 700)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "arXiv:1706.03762v7", attributes: [.font: NSFont.systemFont(ofSize: 14)])), queueContext)
    queueContext.endPDFPage(); queueContext.closePDF()
    let queuePDF = output.appendingPathComponent("queue.pdf"); try (queueBytes as Data).write(to: queuePDF)
    let queueRepository = ReferenceRepository(root: output.appendingPathComponent("QueueReference"))
    let queueModel = ReferenceModel(repository: queueRepository, recognitionLookup: { _ in try await Task.sleep(for: .seconds(2)); return parsed })
    queueModel.importFiles([queuePDF])
    for _ in 0..<250 { if queueModel.recognising { break }; try await Task.sleep(for: .milliseconds(20)) }
    check(!queueModel.busy && queueModel.records.count == 1 && queueModel.recognising, "Imported PDFs are visible and editable while metadata lookup runs")
    queueModel.cancelRecognition(); try await Task.sleep(for: .milliseconds(400))
    check(!queueModel.recognising && queueModel.records[0].authors.isEmpty, "Cancelling background recognition keeps the local PDF without a late metadata write")
    if CommandLine.arguments.contains("--online") {
        let real = try await ReferencePaperLookup.metadata(for: local)
        check(real.year == "2017" && ReferenceText.authors(real.authors).count == 8, "Live arXiv ID lookup returns eight authors and the original submission year")
    }
    print("Passed \(checks) recognition, draft and navigation checks"); exit(0)
 } catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
