import Foundation

// The Swift interpreter needs this availability bridge for the app's native frameworks.
@_cdecl("__isPlatformVersionAtLeast")
public func citationRelevanceHostVersion(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
var count = 0
func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
Task { @MainActor in
    do {
        let repository = ReferenceRepository(root: output.appendingPathComponent("Reference"))
        let saved = try repository.add([ReferenceRecord(key: "LibraryML", fields: ["title": "Machine learning in turbulent combustion", "abstract": "Recent machine learning applications in turbulent combustion."])])[0]
        let context = output.path
        ReferenceCitationPreferences.write(.init(library: saved.library), context: context)
        defer { UserDefaults.standard.removeObject(forKey: ReferenceCitationPreferences.key(context)) }
        let session = ReferenceCitationSession(context: context, repository: repository)
        let source = #"Recent research uses ML in turbulent combustion \cite{"#
        let buffers = ["references.bib": #"@article{Astronomy, title={Observations of distant galaxies}}"#]
        func complete(_ source: String) async -> EditorCompletion.Context? {
            await session.completion(source: source, selection: NSRange(location: source.utf16.count, length: 0), buffers: buffers)
        }
        let first = await complete(source)
        check(first?.items.first?.referenceID == saved.id, "Context may rank a relevant library source above unrelated project entries")
        check(first?.items.first?.annotation == "Topic match", "The editor receives a concise assessment annotation")
        check(first?.items.first?.detail?.contains("Title and abstract") == true, "The editor discloses its source basis")
        check(first?.items.first?.detail?.contains("does not verify") == false, "Method context uses the more specific source reminder")
        check(first?.items.first?.detail?.contains("original method") == true, "Method context asks for source verification")
        for _ in 0..<12 { _ = await complete(source) }
        check(session.libraryLoads == 1 && session.bibliographyPreparations == 1, "Typing reuses both prepared indexes")
        let plain = await complete(#"\cite{"#)
        check(plain?.items.first?.referenceID == nil && plain?.items.first?.annotation == nil, "Without a sentence the original project-first completion remains")
        var revised = saved; revised.fields["abstract"] = "Observations of distant galaxies."
        revised.fields["title"] = "Astronomical observations of distant galaxies"
        _ = try repository.update(revised, expected: saved.revision)
        let refreshed = await complete(source)
        check(session.libraryLoads == 2, "A catalogue revision refreshes the library index on the next request")
        check(refreshed?.items.first?.detail?.contains("Astronomical observations") == false, "Stale topical metadata no longer leads the list")
        let cancellation = Task { await complete(source) }; cancellation.cancel()
        check(await cancellation.value == nil, "Cancelled completion does not deliver a stale result")
        session.release()
        weak var released: ReferenceCitationSession?
        var temporary: ReferenceCitationSession? = ReferenceCitationSession(context: context, repository: repository)
        released = temporary
        _ = await temporary?.completion(source: source, selection: NSRange(location: source.utf16.count, length: 0), buffers: buffers)
        temporary = nil
        check(released == nil, "Prepared tasks do not retain a discarded writing session")
        UserDefaults.standard.setVolatileDomain([NetworkAccessGate.preference: false], forName: UserDefaults.argumentDomain)
        let receipt = ReferenceRecognition.Receipt()
        _ = await ReferenceRecognition.enrich([saved], repository: repository, lookup: { _ in throw ReferenceFailure("Synthetic lookup failure") }, onFailure: { await receipt.fail($0) })
        check(await receipt.failure() == "Synthetic lookup failure", "Manual lookup reports failure instead of silently doing nothing")
        let titleRecords = try repository.add([
            ReferenceRecord(key: "FirstTitle", fields: ["title": "First exact title without identifiers"]),
            ReferenceRecord(key: "SecondTitle", fields: ["title": "Second exact title without identifiers"])
        ])
        let enriched = await ReferenceRecognition.enrich(titleRecords, repository: repository, lookup: { record in
            var response = record; response.fields["abstract"] = "Abstract for " + record.citationKey; return response
        })
        check(enriched.allSatisfy { $0.fields["abstract"] == "Abstract for " + $0.citationKey }, "Title-only lookups have separate cache identities within a batch")
        let secondLibrary = try repository.addLibrary("Second library")
        let secondary = try repository.add([ReferenceRecord(key: "HydrogenSource", fields: ["title": "Hydrogen reactivity and ignition"])], libraryID: secondLibrary.id)[0]
        ReferenceCitationPreferences.write(.init(library: saved.library, libraries: [saved.library, secondLibrary.id]), context: context)
        let union = await complete(#"Hydrogen reactivity affects ignition \cite{"#)
        check(union?.items.contains(where: { $0.referenceID == secondary.id }) == true, "Completion searches the union of selected libraries")
        let unionLoads = session.libraryLoads
        _ = await complete(source)
        check(session.libraryLoads == unionLoads, "Unchanged multi-library scope reuses the prepared index")
        ReferenceCitationPreferences.write(.init(libraries: []), context: context)
        let onlyProject = await complete(#"\cite{"#)
        check(onlyProject?.items.allSatisfy { $0.referenceID == nil } == true, "An empty library selection retains project bibliography suggestions")
        let projectRoot = output.appendingPathComponent("review-refresh")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try #"\documentclass{article}\begin{document}\input{introduction}\end{document}"#.write(to: projectRoot.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let intro = String(repeating: "Original paragraph.\n", count: 80)
        try intro.write(to: projectRoot.appendingPathComponent("introduction.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(projectRoot, historyEnabled: false)
        project.selected = "introduction.tex"
        let identity = project.identity, originalPDF = PDFDocument()
        project.pdf = originalPDF
        NSApplication.shared.setActivationPolicy(.prohibited)
        let editor = MarkdownEditorController(), scroll = editor.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let documentID = identity.uuidString + project.selected
        editor.update(intro, size: 14, serif: false, document: documentID)
        editor.textView?.setSelectedRange(NSRange(location: 50, length: 4))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        let origin = scroll.contentView.bounds.origin
        let revisedIntro = intro.replacingOccurrences(of: "Original paragraph.", with: "Reviewed paragraph.")
        try revisedIntro.write(to: projectRoot.appendingPathComponent("introduction.tex"), atomically: true, encoding: .utf8)
        try project.reloadReviewedFiles()
        editor.update(project.buffers[project.selected]!, size: 14, serif: false, document: documentID)
        check(project.identity == identity && project.selected == "introduction.tex", "Review refresh retains the active source and project identity")
        check(editor.textView?.selectedRange() == NSRange(location: 50, length: 4) && scroll.contentView.bounds.origin == origin, "The retained editor keeps selection and scroll position")
        check(project.pdf === originalPDF && !project.dirty, "The last PDF remains visible while accepted sources refresh")
        project.buffers["introduction.tex"] = "Unsaved local edit"
        do { try project.reloadReviewedFiles(); check(false, "Unsaved buffer was discarded") }
        catch { check(project.buffers["introduction.tex"] == "Unsaved local edit", "Review refresh preserves new unsaved edits") }
        let modeStore = UserDefaults(suiteName: "remile.overleaf-mode-test." + UUID().uuidString)!, connectionID = UUID()
        check(OverleafSyncPreference.live(connectionID, store: modeStore), "New Overleaf projects prefer Live")
        OverleafSyncPreference.choose(false, for: connectionID, store: modeStore)
        check(!OverleafSyncPreference.live(connectionID, store: modeStore), "An explicit Private choice is remembered")
        OverleafSyncPreference.choose(true, for: connectionID, store: modeStore)
        check(OverleafSyncPreference.live(connectionID, store: modeStore), "A later Live choice is remembered")
        print("Passed \(count) citation relevance session checks. No UI or network operations.")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
