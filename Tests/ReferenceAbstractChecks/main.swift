import Foundation

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: " + message) }
let fixture = Data(#"{"doi":"https://doi.org/10.1234/example","abstract_inverted_index":{"Ammonia":[0],"and":[1],"hydrogen":[2],"have":[3],"different":[4],"reactivity.":[5]}}"#.utf8)
Task { @MainActor in
 do {
    let original = ReferenceRecord(key: "KeepKey", fields: ["title": "Ammonia and hydrogen properties", "doi": "10.1234/example", "author": "Writer, Actual", "year": "2025"])
    let parsed = try ReferencePaperLookup.openAbstract(fixture, doi: "10.1234/example")
    check(parsed == "Ammonia and hydrogen have different reactivity.", "An inverted abstract is reconstructed in position order")
    check(try ReferencePaperLookup.openAbstract(fixture, doi: "10.1234/wrong") == nil, "An unrelated DOI cannot supply an abstract")
    let alias = Data(#"{"doi":"10.1234/canonical","locations":[{"doi":"https://doi.org/10.1234/example"}],"abstract_inverted_index":{"Ammonia":[0],"and":[1],"hydrogen":[2],"have":[3],"different":[4],"reactivity.":[5]}}"#.utf8)
    check(try ReferencePaperLookup.openAbstract(alias, doi: "10.1234/example") == parsed, "An explicit location DOI can verify a secondary DOI")
    for json in [#"{"a":[0],"b":[0]}"#, #"{"a":[0],"b":[2]}"#, #"{"a":[-1]}"#, #"{"a":[3000]}"#] {
        let bad = Data(("{\"doi\":\"10.1234/example\",\"abstract_inverted_index\":" + json + "}").utf8)
        check(try ReferencePaperLookup.openAbstract(bad, doi: "10.1234/example") == nil, "Malformed or unbounded positions are rejected")
    }
    let enriched = try await ReferencePaperLookup.fillingAbstract(original, deadline: .distantFuture, load: { _, _ in fixture })
    check(enriched.fields["abstract"] == parsed && enriched.id == original.id && enriched.key == original.key, "Abstract fill retains record identity and citation key")
    let preserved = try await ReferencePaperLookup.fillingAbstract(enriched, deadline: .distantFuture, load: { _, _ in preconditionFailure("An existing abstract must not be fetched again") })
    check(preserved == enriched, "Existing abstracts skip the fallback request")
    let unavailable = try await ReferencePaperLookup.fillingAbstract(original, deadline: .distantFuture, load: { _, _ in throw URLError(.cannotConnectToHost) })
    check(unavailable == original, "An unavailable abstract does not discard recognised metadata")
    do { _ = try await ReferencePaperLookup.fillingAbstract(original, deadline: .distantFuture, load: { _, _ in throw CancellationError() }); check(false, "Cancellation swallowed") }
    catch is CancellationError { check(true, "Cancellation propagates from optional lookup") }
    check(try ReferenceExport.bibtex([enriched], includeAbstract: false).contains("abstract =") == false, "BibTeX export can omit the stored abstract")
    check(try ReferenceExport.bibtex([enriched], includeAbstract: true).contains("abstract ="), "BibTeX export can include the same stored abstract")
    var manual = original; manual.fields["abstract"] = "My existing abstract."
    let merged = try ReferenceRecognition.merged(manual, with: enriched)
    check(merged.fields["abstract"] == manual.fields["abstract"], "Lookup cannot overwrite an existing user abstract")
    let change = try ReferenceCleanup.onlineChange(original, local: original, fetched: enriched)
    check(change?.fields == ["abstract"] && original.fields["abstract"] == nil, "Clean up previews an abstract without writing it")
    check(ReferenceCleanup.needsLookup(original) && !ReferenceCleanup.needsLookup(enriched), "Complete contributor, year and abstract fields leave the missing-details queue")
    check(ReferenceColumn.publication.displayedValue(original) == "—" && ReferenceColumn.publication.value(original).isEmpty, "Missing publication is a display placeholder, never stored metadata")
    check(ReferenceColumn.author.label == "Author / Editor", "The contributor heading names both roles")
    check(Set(ReferenceRelevance.tokens("H₂ NH₃ H_{2} NH_{3}")) == ["hydrogen", "ammonia"], "Chemical notation variants share two identity-preserving terms")
    check(!ReferenceRelevance.tokens("H2O NH4").contains("hydrogen") && !ReferenceRelevance.tokens("H2O NH4").contains("ammonia"), "Water and ammonium cannot become hydrogen and ammonia")
    check(ReferenceRelevance.tokens("ML") == ReferenceRelevance.tokens("machine learning") && ReferenceRelevance.tokens("ML").count == 1, "An abbreviation and its phrase contribute one term")
    check(ReferenceRelevance.tokens("DNNs") == ReferenceRelevance.tokens("deep neural networks"), "Deep neural network notation is symmetric")
    check(ReferenceRelevance.tokens("large-eddy simulation") == ReferenceRelevance.tokens("large eddy simulation"), "Hyphenation does not split a recognised phrase")
    let numeric = ReferenceRelevance.assess(.init(title: "3.0 2.0", abstract: ""), context: .init("3.0 2.0"))
    check(numeric?.label != "Topic match", "Numbers alone cannot produce a strong topic label")
    let suite = "remile.citation-test." + UUID().uuidString, store = UserDefaults(suiteName: "remile.citation-scope-test." + UUID().uuidString)!
    defer { store.removeObject(forKey: ReferenceCitationPreferences.key(suite)) }
    let first = UUID(), second = UUID()
    let old = try JSONSerialization.data(withJSONObject: ["library": first.uuidString])
    store.set(old, forKey: ReferenceCitationPreferences.key(suite))
    check(ReferenceCitationPreferences.read(suite, store: store).selectedLibraries == [first], "Existing single-library choices migrate without widening scope")
    ReferenceCitationPreferences.write(.init(library: first, libraries: [first, second]), context: suite, store: store)
    check(ReferenceCitationPreferences.read(suite, store: store).selectedLibraries == [first, second], "A document can retain multiple citation libraries")
    ReferenceCitationPreferences.write(.init(libraries: []), context: suite, store: store)
    check(ReferenceCitationPreferences.read(suite, store: store).selectedLibraries.isEmpty, "An intentional empty selection stays empty")
    let repository = ReferenceRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("scope-library"))
    let lib = try repository.addLibrary("Second")
    let a = try repository.add([original])[0]
    let b = try repository.add([ReferenceRecord(key: "SecondPaper", fields: ["title": "Other source in second library"])], libraryID: lib.id)[0]
    let response = try ReferenceCLI.response(["suggest", "--libraries", a.library.uuidString + "," + b.library.uuidString], repository: repository)
    check((response["suggestions"] as? [[String: Any]])?.count == 2, "The CLI uses the same multi-library union")
    do { _ = try ReferenceCLI.response(["suggest", "--libraries", "not-an-id"], repository: repository); check(false, "Invalid scope accepted") }
    catch { check(true, "Invalid multi-library IDs fail explicitly") }
    if CommandLine.arguments.contains("--online") {
        let real = ReferenceRecord(fields: ["title": "Attention Is All You Need", "doi": "10.48550/arXiv.1706.03762"])
        let lookedUp = try await ReferencePaperLookup.fillingAbstract(real, deadline: Date().addingTimeInterval(30))
        check((lookedUp.fields["abstract"] ?? "").count > 100, "Public OpenAlex lookup supplies an identifier-checked abstract")
    }
    print("Passed \(checks) abstract, scope and notation checks"); exit(0)
 } catch { print("FAILED: \(error)"); exit(1) }
}
RunLoop.main.run()
