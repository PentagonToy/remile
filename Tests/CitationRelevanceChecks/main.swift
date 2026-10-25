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
        print("Passed \(count) citation relevance session checks. No UI or network operations.")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
