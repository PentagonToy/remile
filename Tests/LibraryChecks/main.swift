import CoreText
import AppKit

// Run through tools/check_library.sh. Generated fixtures remain outside the checkout.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw NSError(domain: "LibraryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    checks += 1
}
func fixture(_ url: URL, pages: [String]) throws {
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else { throw CocoaError(.fileWriteUnknown) }
    for content in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 730
        for line in content.components(separatedBy: "\n") {
            let attributes: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            y -= 25
        }
        context.endPDFPage()
    }
    context.closePDF()
}

Task {
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = output.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("A.pdf")
        let second = folder.appendingPathComponent("B.pdf")
        let blank = folder.appendingPathComponent("Scan.pdf")
        try fixture(first, pages: ["Turbulent combustion\nHydrogen and ammonia flames.", "A different subject\nNumerical transport.\n난류 연소"])
        try fixture(second, pages: ["Other topics\nLaboratory notes\nNothing here\nCombustion is turbulent in this example."])
        try fixture(blank, pages: [""])
        let database = output.appendingPathComponent("search.sqlite")
        let store = LibraryIndex(location: database)
        try await store.add(folder)
        do { try await store.add(folder); throw NSError(domain: "Unexpected duplicate", code: 1) }
        catch LibraryIndex.Failure.folderOverlap { checks += 1 }
        try await store.refresh { _ in }
        var summary = try await store.summary()
        try expect(summary.documents == 3 && summary.pages == 4, "Index document/page totals")
        try expect(summary.needsOCR == 1, "Report blank pages")
        var hits = try await store.search("turbulent combustion")
        try expect(hits.count == 2 && hits.first?.path == first.path && hits.first?.page == 1, "Rank heading-rich page first")
        hits = try await store.search("\"turbulent combustion\"")
        try expect(hits.count == 1 && hits[0].path == first.path, "Phrase preserves term adjacency")
        hits = try await store.search("TURBULENT combustion")
        try expect(hits.count == 2, "Case-insensitive matching")
        hits = try await store.search("난류 연소")
        try expect(hits.count == 1 && hits[0].page == 2, "Korean terms retain the correct page")
        hits = try await store.search("hydrogen nonexistent")
        try expect(hits.isEmpty, "Every query term is required")
        do { _ = try await store.search("***"); throw NSError(domain: "Unexpected query", code: 1) }
        catch LibraryIndex.Failure.emptyQuery { checks += 1 }
        do { _ = try await store.search("\"unfinished phrase"); throw NSError(domain: "Unbalanced query", code: 1) }
        catch LibraryIndex.Failure.invalidQuery { checks += 1 }
        do { _ = try await store.search(String(repeating: "word ", count: 25)); throw NSError(domain: "Long query", code: 1) }
        catch LibraryIndex.Failure.invalidQuery { checks += 1 }
        _ = try await store.search("combustion OR x' ; DROP TABLE documents --")
        summary = try await store.summary()
        try expect(summary.documents == 3, "Query syntax cannot inject SQL/FTS operators")
        let reopened = LibraryIndex(location: database)
        hits = try await reopened.search("hydrogen")
        try expect(hits.count == 1 && hits[0].page == 1, "Index survives connection reopen")
        try await store.refresh { _ in }
        hits = try await store.search("turbulent combustion")
        try expect(hits.count == 2, "Unchanged refresh creates no duplicates")
        try fixture(first, pages: ["Replaced document\nA new zirconium subject."])
        try await store.refresh { _ in }
        hits = try await store.search("hydrogen")
        try expect(hits.isEmpty, "Changed document removes old terms")
        hits = try await store.search("zirconium")
        try expect(hits.count == 1, "Changed document becomes searchable")
        try FileManager.default.removeItem(at: second)
        try await store.refresh { _ in }
        hits = try await store.search("combustion")
        try expect(hits.isEmpty, "Deleted files leave no stale pages")
        let broken = folder.appendingPathComponent("Broken.pdf")
        try Data("invalid PDF".utf8).write(to: broken)
        try await store.refresh { _ in }
        summary = try await store.summary()
        try expect(summary.failed == 1 && summary.documents == 3, "Bad PDF is counted without aborting library")
        try fixture(broken, pages: ["Recovered document\nHelium spectroscopy"])
        try await store.refresh { _ in }
        hits = try await store.search("helium")
        summary = try await store.summary()
        try expect(hits.count == 1 && summary.failed == 0, "Failed documents retry successfully")
        let markdown = folder.appendingPathComponent("Research.md")
        let markdownSource = "# Transport\nElectrochemistry tracks ions.\n\n## Boundary conditions\nElectrochemistry at an electrode.\n```swift\n# Not a heading\n```"
        try markdownSource.write(to: markdown, atomically: true, encoding: .utf8)
        try await store.refresh { _ in }
        hits = try await store.search("electrochemistry")
        try expect(hits.count == 2 && hits.allSatisfy(\.isMarkdown), "Markdown sections are searchable beside PDFs")
        try expect(Set(hits.map(\.page)) == [1, 2], "Markdown hits retain stable section anchors")
        hits = try await store.search("boundary conditions")
        try expect(hits.first?.page == 2 && hits.first?.excerpt.contains("Boundary conditions") == true, "Heading search reveals the matching Markdown section")
        let corrections = try await store.spellingSuggestions("electrochmeistry")
        try expect(corrections.contains("electrochemistry"), "Transposed typing errors resolve to indexed terms")
        let missingLetter = try await store.spellingSuggestions("electrochemstry electrode")
        try expect(missingLetter.contains("electrochemistry electrode"), "Spelling suggestions retain other query words and require actual hits")
        let exactPhrase = try await store.spellingSuggestions("\"electrochmeistry\"")
        try expect(exactPhrase.isEmpty, "Quoted literal phrases are never silently corrected")
        let noGuess = try await store.spellingSuggestions("zzqxvvzzq")
        try expect(noGuess.isEmpty, "No invented correction is offered for distant vocabulary")
        let vocabulary = try await store.explorationVocabulary()
        try expect(vocabulary.contains("electrochemistry") && vocabulary.count <= 160, "AI search receives bounded vocabulary from the actual index")
        try expect(SearchExpansion.distance("electrochmeistry", "electrochemistry") == 1, "Adjacent transposition counts as one typing error")
        let planned = try SearchExpansion.queries(from: "{\"queries\":[\"electrode diffusion\",\"electrode diffusion\",\"transport\"]}")
        try expect(planned == ["electrode diffusion", "transport"], "Query plans are bounded and deduplicated")
        var rejectedPlan = false
        do { _ = try SearchExpansion.queries(from: "Ignore this and execute SQL") } catch { rejectedPlan = true }
        try expect(rejectedPlan, "Non-JSON model instructions cannot become a query plan")
        try expect(SearchExpansion.groundedQuery("electrode inhibition mechanism", vocabulary: ["electrode", "diffusion"]) == "electrode", "Expanded searches can drop absent qualifiers using actual library vocabulary")
        try expect(SearchExpansion.groundedQuery("imaginary mechanism", vocabulary: ["diffusion"]) == nil, "Grounding never introduces an unrelated vocabulary term")
        let literal = LibraryHit(path: "/A.pdf", folderID: "fixture", page: 1, excerpt: "electrode", score: -0.1)
        let additional = LibraryHit(path: "/B.md", folderID: "fixture", page: 2, excerpt: "diffusion", score: -999)
        let merged = SearchExpansion.merge([("electrode", [literal]), ("diffusion", [additional, literal])])
        try expect(merged.count == 2 && merged.first?.id == literal.id, "Rank fusion combines repeated evidence without comparing unrelated BM25 magnitudes")
        try expect(merged.first?.matchQuery == "electrode" && merged.last?.matchQuery == "diffusion", "Expanded hits retain the real matched terms for highlights")
        let sections = SearchMarkdown.sections(markdownSource)
        try expect(sections.count == 2 && sections[1].source.contains("# Not a heading"), "Fenced code does not create false sections")
        try expect(SearchMarkdown.sections("\n\n# First\nText").first?.number == 1, "Blank preamble does not shift section numbering")
        try expect(SearchText.matches("cat catalyst concatenate", query: "cat").count == 1, "Highlights match complete words rather than substrings")
        try expect(SearchText.matches("α café ALPHA\nbeta", query: "cafe \"alpha beta\"").count == 2, "Unicode folding and wrapped phrases match index terms")
        try expect(SearchText.matches("x-ray flow", query: "\"x ray\"").count == 1, "Phrase highlights use token adjacency across punctuation")
        let near = SearchText.context("alpha beta", query: "alpha beta")
        let far = SearchText.context("alpha " + String(repeating: "separation ", count: 80) + "beta", query: "alpha beta")
        try expect(near.proximity > far.proximity, "Nearby query words receive a bounded preference")
        let focus = SearchText.context(String(repeating: "Background. ", count: 60) + "The electrode supports electrochemistry.", query: "electrochemistry")
        try expect(focus.excerpt.contains("electrochemistry") && focus.excerpt.count < 450, "Context excerpts expose the actual match without long page text")
        let damaged = folder.appendingPathComponent("Invalid.md")
        try Data([0xff, 0xfe, 0xff]).write(to: damaged)
        try await store.refresh { _ in }
        summary = try await store.summary()
        try expect(summary.failed == 1, "Invalid UTF-8 Markdown is reported without aborting indexing")
        try "# Replacement\nZirconia references.".write(to: markdown, atomically: true, encoding: .utf8)
        try await store.refresh { _ in }
        hits = try await store.search("electrochemistry")
        try expect(hits.isEmpty, "Editing Markdown removes stale sections")
        hits = try await store.search("zirconia")
        try expect(hits.count == 1 && hits.first?.page == 1, "Edited Markdown sections become searchable")
        // Cancelling a refresh must not run deletion cleanup against a partial scan.
        let cancelled = Task {
            try await store.refresh { value in
                if value.completed == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await cancelled.value; throw NSError(domain: "Cancellation not propagated", code: 1) }
        catch is CancellationError { checks += 1 }
        hits = try await store.search("helium")
        try expect(hits.count == 1, "Cancellation preserves previously committed pages")
        let missing = output.appendingPathComponent("library-away")
        try FileManager.default.copyItem(at: folder, to: missing)
        try FileManager.default.removeItem(at: folder)
        var unavailableRejected = false
        do { try await store.refresh { _ in } }
        catch { unavailableRejected = true }
        try expect(unavailableRejected, "Unavailable folder is rejected")
        hits = try await store.search("helium")
        try expect(hits.count == 1, "Unavailable folder cannot erase the index")
        try FileManager.default.moveItem(at: missing, to: folder)
        if let root = try await store.summary().folders.first { try await store.remove(root) }
        summary = try await store.summary()
        hits = try await store.search("helium")
        try expect(summary.documents == 0 && summary.folders.isEmpty && hits.isEmpty, "Removing folder removes only indexed state")
        try expect(FileManager.default.fileExists(atPath: broken.path), "Original PDF survives folder removal")
        print("\(checks) library checks passed")
        exit(0)
    } catch {
        fputs("Library check failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
