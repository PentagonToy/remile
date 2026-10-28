import CoreText
import AppKit

// Run through tools/check_library.sh. Generated fixtures remain outside the checkout.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw NSError(domain: "LibraryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
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
        let ranked = try await store.rankedSearch("How can hydrogen burn in flames?")
        try expect(ranked.first?.path == first.path && ranked.first?.page == 1, "B0 searches natural questions without AI or all-token filtering")
        let rankedPhrase = try await store.rankedSearch("\"turbulent combustion\"")
        try expect(rankedPhrase.count == 1 && rankedPhrase[0].path == first.path, "B0 keeps exact quoted phrase constraints")
        let partialRanked = try await store.rankedSearch("hydrogen nonexistent")
        try expect(partialRanked.count == 1 && partialRanked[0].path == first.path, "B0 preserves partial lexical candidates")
        let expandedRanked = try await store.rankedSearch("hydrogen", expansions: ["numerical transport"])
        try expect(expandedRanked.contains { $0.page == 2 && $0.path == first.path }, "Guided fusion retains original and expanded candidates")
        try expect(ranked[0].matchQuery?.contains("hydrogen") == true && ranked[0].excerpt.contains("Hydrogen"), "B0 highlights actual matched surface forms")
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
        let staleRanked = try await store.rankedSearch("hydrogen")
        try expect(staleRanked.isEmpty, "Changed file invalidates resident sparse index")
        hits = try await store.search("zirconium")
        try expect(hits.count == 1, "Changed document becomes searchable")
        try FileManager.default.removeItem(at: second)
        try await store.refresh { _ in }
        hits = try await store.search("combustion")
        try expect(hits.isEmpty, "Deleted files leave no stale pages")
        let deletedRanked = try await store.rankedSearch("combustion")
        try expect(deletedRanked.isEmpty, "Removed file invalidates sparse postings")
        let broken = folder.appendingPathComponent("Broken.pdf")
        try Data("invalid PDF".utf8).write(to: broken)
        try await store.refresh { _ in }
        summary = try await store.summary()
        try expect(summary.failed == 1 && summary.documents == 3, "Bad PDF is counted without aborting library")
        let indexed = try await store.indexedDocuments()
        try expect(indexed.count == 3 && indexed.filter(\.failed).count == 1, "Per-document status distinguishes failed indexing")
        try expect(indexed.first?.failed == true && indexed.first?.status == "Not indexed", "Documents needing attention appear first")
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
        let repeatedContext = SearchText.context(String(repeating: "alpha ", count: 2000) + String(repeating: "beta ", count: 2000), query: "alpha beta")
        try expect(repeatedContext.proximity == near.proximity && repeatedContext.excerpt.contains("alpha beta"), "Repeated matches retain the shortest complete query window")
        let overlapping = SearchText.context("alpha beta gamma", query: "\"alpha beta gamma\" beta")
        try expect(overlapping.excerpt == "alpha beta gamma" && overlapping.proximity == 1 / (1 + 16.0 / 80), "A phrase ending after a later word retains its full span")
        let incomplete = SearchText.context("alpha alpha", query: "alpha missing")
        try expect(incomplete.proximity == 0 && incomplete.excerpt == "alpha alpha", "Missing query groups never receive a complete-window boost")
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
        let questionFolder = output.appendingPathComponent("questions")
        try FileManager.default.createDirectory(at: questionFolder, withIntermediateDirectories: true)
        try fixture(questionFolder.appendingPathComponent("Methods.pdf"), pages: [
            "Coupling methods\nPressure and velocity coupling for incompressible flow.",
            "Transport methods\nUpwind stabilisation for convection dominated flow.",
            "Unrelated flow\nPressure waves in compressible flow."
        ])
        let questionIndex = LibraryIndex(location: output.appendingPathComponent("questions.sqlite"))
        try await questionIndex.add(questionFolder)
        try await questionIndex.refresh { _ in }
        let coupling = try await questionIndex.search("How are pressure and velocity coupled for incompressible flow?")
        try expect(coupling.count == 1 && coupling.first?.page == 1, "Question keywords retain every substantive constraint")
        try expect(coupling.first?.matchQuery?.contains("coupling") == true, "Highlight the actual inflected word on the retrieved page")
        let literalQuestion = try await questionIndex.search("How are pressure and velocity coupled for incompressible flow?", interpretQuestions: false)
        try expect(literalQuestion.isEmpty, "Disabling question interpretation restores literal search")
        let transport = try await questionIndex.search("Why is upwinding used for convection dominated flow?")
        try expect(transport.count == 1 && transport.first?.page == 2, "Question inflections find indexed word families")
        let partialQuestion = try await questionIndex.rankedSearch("Why is upwinding used for convection dominated flow?")
        try expect(partialQuestion.first?.page == 2, "Native B0 passage/coverage rank prefers the complete transport explanation")
        _ = try await questionIndex.rankedSearch("pressure")
        let externalIndex = LibraryIndex(location: output.appendingPathComponent("questions.sqlite"))
        try fixture(questionFolder.appendingPathComponent("Methods.pdf"), pages: ["New document\nDistinctive xenon spectroscopy."])
        try await externalIndex.refresh { _ in }
        let afterExternal = try await questionIndex.rankedSearch("xenon")
        try expect(afterExternal.count == 1, "Other SQLite connection changes invalidate cached sparse index")
        let strict = try await questionIndex.search("upwinding convection")
        try expect(strict.isEmpty, "Ordinary keywords remain literal")
        let quotedQuestion = try await questionIndex.search("\"How are pressure and velocity coupled\"")
        try expect(quotedQuestion.isEmpty, "Quoted questions remain literal phrases")
        try expect(SearchQuestion("How is pressure not coupled to velocity?") == nil, "Do not silently remove negation")
        try expect(SearchQuestion("비압축성 유동에서 압력은 어떻게 연결하나요?") == nil, "No unsupported cross-language expansion")
        try expect(SearchQuestion("what is x?") == nil, "Very short questions keep literal semantics")
        let forceRoot = output.appendingPathComponent("force-library")
        let otherRoot = output.appendingPathComponent("other-library")
        for root in [forceRoot, otherRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let forceFile = forceRoot.appendingPathComponent("same.md"), otherFile = otherRoot.appendingPathComponent("other.md")
        for file in [forceFile, otherFile] {
            try "# alpha".write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        }
        let forced = LibraryIndex(location: output.appendingPathComponent("force.sqlite"))
        try await forced.add(forceRoot); try await forced.add(otherRoot); try await forced.refresh { _ in }
        let folderID = try await forced.summary().folders.first { $0.path == forceRoot.path }!.id
        for file in [forceFile, otherFile] {
            let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
            let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: Data("# omega".utf8)); try handle.close()
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        }
        try await forced.refresh { _ in }
        let skippedHits = try await forced.search("omega")
        try expect(skippedHits.isEmpty, "Incremental refresh skips unchanged metadata")
        try await forced.refresh(folderID: folderID, force: true) { _ in }
        let forcedHits = try await forced.search("omega")
        try expect(forcedHits.count == 1 && forcedHits[0].path == forceFile.path, "Folder reindex rebuilds unchanged metadata without refreshing other folders")
        try await forced.refresh(folderID: folderID, force: true) { _ in }
        let repeatedHits = try await forced.search("omega")
        try expect(repeatedHits.count == 1, "Repeated forced reindex does not duplicate pages")
        let maths = output.appendingPathComponent("maths")
        try FileManager.default.createDirectory(at: maths, withIntermediateDirectories: true)
        for (name, symbol) in [("A", "α"), ("B", "β"), ("C", "α")] {
            try ("# Momentum\nForce = " + symbol).write(to: maths.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        }
        let mathsIndex = LibraryIndex(location: output.appendingPathComponent("maths.sqlite"))
        try await mathsIndex.add(maths); try await mathsIndex.refresh { _ in }
        let equations = try await mathsIndex.rankedSearch("momentum")
        try expect(equations.count == 2, "Duplicate suppression keeps distinct mathematical symbols and removes identical content")
        let mathsFolder = try await mathsIndex.summary().folders[0]
        try await mathsIndex.remove(mathsFolder)
        let removedFolder = try await mathsIndex.rankedSearch("momentum")
        try expect(removedFolder.isEmpty, "Removing a folder clears loaded sparse ranking data")
        let pagingRoot = output.appendingPathComponent("paging")
        try FileManager.default.createDirectory(at: pagingRoot, withIntermediateDirectories: true)
        for i in 0..<205 { try "# Paging fixture \(i)\nPagination marker unique \(i).".write(to: pagingRoot.appendingPathComponent("\(i).md"), atomically: true, encoding: .utf8) }
        let pagingIndex = LibraryIndex(location: output.appendingPathComponent("paging.sqlite"))
        try await pagingIndex.add(pagingRoot); try await pagingIndex.refresh { _ in }
        let firstPage = try await pagingIndex.rankedPage("pagination"), nextPage = try await pagingIndex.rankedPage("pagination", offset: 200)
        try expect(firstPage.hits.count == 200 && firstPage.hasMore && nextPage.hits.count == 5 && !nextPage.hasMore, "Paged search reaches matches beyond 200 without retaining their full text")
        try expect(Set((firstPage.hits + nextPage.hits).map(\.id)).count == 205, "Result pages have distinct stable locations")
        let scienceRoot = output.appendingPathComponent("science")
        try FileManager.default.createDirectory(at: scienceRoot, withIntermediateDirectories: true)
        let fixtures: [(String, String, String)] = [
            ("greek", "k-ε turbulence closure", "epsilon"),
            ("formula", "H₂ and NH₃ flame kinetics", "H2 NH3"),
            ("ligature", "A ﬁnite volume solver", "finite"),
            ("wrapped", "Predicting turbu-\nlence statistics", "turbulence"),
            ("symbol", "The φ and τ values", "phi tau"),
            ("unicode", "연소 modelling", "연소"),
            ("body", "Combustion appears in the main text.", "combustion"),
            ("uncertain", "References\nCombustion is discussed here without a citation list.", "combustion"),
            ("appendix", "References\n[1] Smith 2020\n[2] Jones 2021\nAppendix A\nA combustion experiment.", "combustion")
        ]
        for (name, body, _) in fixtures { try body.write(to: scienceRoot.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8) }
        try "References\n[1] Combustion journal 2020\n[2] Combustion methods 2021".write(to: scienceRoot.appendingPathComponent("bibliography.md"), atomically: true, encoding: .utf8)
        let scienceURL = output.appendingPathComponent("science.sqlite"), science = LibraryIndex(location: scienceURL)
        try await science.add(scienceRoot); try await science.refresh { _ in }
        _ = try await science.rankedPage("combustion")
        let warmedPreparation = await science.lastRankerPreparation
        try expect(warmedPreparation == "memory", "Refresh prepares ranking before the first search")
        for (name, _, query) in fixtures {
            let hits = try await science.rankedPage(query, includeBibliography: false)
            try expect(hits.hits.contains(where: { $0.path.hasSuffix("/" + name + ".md") }), "Scientific fixture is retrieved: " + name)
        }
        let noBibliography = try await science.rankedPage("combustion", includeBibliography: false)
        try expect(!noBibliography.hits.contains(where: { $0.path.hasSuffix("/bibliography.md") }), "Detected bibliography-only matches stay out of main-text search")
        let withBibliography = try await science.rankedPage("combustion", includeBibliography: true)
        try expect(withBibliography.hits.contains(where: { $0.path.hasSuffix("/bibliography.md") }), "Including bibliography makes the complete reference-list evidence available")
        let phrase = try await science.rankedPage("\"H2 and NH3\"", includeBibliography: false)
        try expect(phrase.hits.contains(where: { $0.path.hasSuffix("/formula.md") }), "Quoted FTS filtering shares chemical normalisation with B0")
        let ftsFormula = try await science.search("H2 NH3", interpretQuestions: false)
        try expect(ftsFormula.contains(where: { $0.path.hasSuffix("/formula.md") }), "Direct FTS search shares normalisation")
        let restoredScience = LibraryIndex(location: scienceURL)
        _ = try await restoredScience.rankedPage("combustion", includeBibliography: false)
        let preparation = await restoredScience.lastRankerPreparation
        try expect(preparation == "disk", "A fresh library actor restores the finished disk index")
        try "New oxygen benchmark.".write(to: scienceRoot.appendingPathComponent("body.md"), atomically: true, encoding: .utf8)
        try await science.refresh { _ in }
        let changedScience = try await science.rankedPage("oxygen", includeBibliography: false)
        try expect(changedScience.hits.contains(where: { $0.path.hasSuffix("/body.md") }), "A changed document invalidates global weights and refreshes derived text")
        let source = "k-ε model with H₂ and a ﬁnite mesh. turbu-\nlence"
        for query in ["epsilon", "H2", "finite", "turbulence"] {
            let matches = SearchText.matches(source, query: query)
            try expect(!matches.isEmpty && matches.allSatisfy { NSMaxRange($0.range) <= (source as NSString).length }, "Original highlight ranges survive alias: " + query)
        }
        var inBibliography = false
        let repeated = Set([SearchPageStructure.marginKey("Combustion and Flame 2026")])
        let structured = SearchPageStructure.analyse("Combustion and Flame 2026\nAuthors\n\nA pressure experiment\nwith several lines\nin the actual body\nand useful results\n23", repeatedMargins: repeated, inBibliography: &inBibliography)
        try expect(!structured.body.contains("Combustion and Flame") && structured.body.contains("pressure"), "Known repeated margin lines do not become topic evidence")
        var continuation = true
        let chapter = SearchPageStructure.analyse("A new chapter without a numbered heading\nCombustion models and their governing equations.", inBibliography: &continuation)
        try expect(!continuation && chapter.body.contains("Combustion"), "A page without citation evidence is never silently carried into a preceding bibliography")
        let cacheFile = scienceURL.deletingPathExtension().appendingPathExtension("body-rank")
        try Data("broken cache".utf8).write(to: cacheFile)
        let damagedCache = LibraryIndex(location: scienceURL)
        let recoveredHits = try await damagedCache.rankedPage("oxygen", includeBibliography: false)
        try expect(recoveredHits.hits.contains(where: { $0.path.hasSuffix("/body.md") }), "Corrupt disposable caches rebuild without losing searchable documents")
        try "Combustion is measured in the main text.\nReferences\n[1] Combustion journal 2020\n[2] Combustion handbook 2021".write(to: scienceRoot.appendingPathComponent("mixed.md"), atomically: true, encoding: .utf8)
        try await science.refresh { _ in }
        let mixed = try await science.rankedPage("combustion", includeBibliography: false)
        let mixedExcerpt = mixed.hits.first { $0.path.hasSuffix("/mixed.md") }?.excerpt ?? ""
        try expect(mixedExcerpt.contains("main text") && !mixedExcerpt.contains("Combustion journal"), "Main-text excerpts do not quote a detected reference list on the same page")
        let plainBookmark = try scienceRoot.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let renewedURL = try LibraryFolder.verifiedUnscopedURL(plainBookmark, path: scienceRoot.path)
        try expect(renewedURL.path == scienceRoot.standardizedFileURL.resolvingSymlinksInPath().path, "A legacy grant resolves only to the same registered folder")
        do {
            _ = try LibraryFolder.verifiedUnscopedURL(plainBookmark, path: pagingRoot.path)
            throw NSError(domain: "Wrong folder grant accepted", code: 1)
        } catch LibraryIndex.Failure.inaccessible { checks += 1 }
        do {
            _ = try LibraryFolder.verifiedUnscopedURL(Data("invalid".utf8), path: scienceRoot.path)
            throw NSError(domain: "Corrupt grant accepted", code: 1)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain { checks += 1 }
        let originalScope = LibraryFolder(id: "fixture", path: scienceRoot.path, bookmark: plainBookmark)
        let scopeURL = try originalScope.url()
        try expect(scopeURL.standardizedFileURL.resolvingSymlinksInPath().path == renewedURL.path, "Library access survives a bookmark without the old signing scope")
        let problems = try await store.indexedDocuments(issuesOnly: true)
        try expect(problems.allSatisfy { $0.failed || $0.emptyPages > 0 }, "Search coverage lists only files with unavailable searchable text")
        let coverage = try await store.summary()
        try expect(coverage.needsAttention >= problems.count, "Coverage counts affected files rather than all library documents")
        print("\(checks) library checks passed")
        exit(0)
    } catch {
        fputs("Library check failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
