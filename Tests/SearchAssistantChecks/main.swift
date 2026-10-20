import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw NSError(domain: "SearchAssistantChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; checks += 1
}
Task { @MainActor in
    do {
        let hits = (1...20).map { LibraryHit(path: "/fixture/Notes\($0).\($0.isMultiple(of: 2) ? "md" : "pdf")", folderID: "fixture", page: $0, excerpt: String(repeating: "Concentration controls electrode current. ", count: 20), score: -1) }
        let evidence = AssistantEvidence.make(hits.map(\.assistantPassage))
        try check(evidence.count <= 6 && evidence.map(\.text).joined().utf8.count <= 2600, "Assistant evidence is bounded")
        try check(AssistantEvidence.make([hits[0], hits[0]].map(\.assistantPassage)).count == 1, "Repeated locations do not duplicate evidence")
        try check(AssistantEvidence.bounded("😀한글", bytes: 5) == "😀", "Evidence limits preserve Unicode characters")
        try check(AssistantEvidence.citations(in: "Current rises [1].", sources: evidence)?.map(\.number) == [1], "Citations resolve to supplied locations")
        try check(AssistantEvidence.citations(in: "Invented [99].", sources: evidence) == nil, "Unknown source numbers are rejected")
        try check(AssistantEvidence.citations(in: "Valid [1] but invented [99999999999999999999999999999].", sources: evidence) == nil, "Overflowing source identifiers cannot bypass citation validation")
        try check(AssistantEvidence.citations(in: "Uncited answer.", sources: evidence) == nil, "Uncited generation is not presented as a supported answer")
        let readerPassage = AssistantPassage(location: AssistantLocation(path: "/fixture/Reader.pdf", unit: 7, label: "Page 7"), text: "A reader can supply its own selected passage.")
        try check(AssistantEvidence.make([readerPassage]).first?.location.unit == 7, "Reader evidence works without library hit ownership")
        let noCite = AssistantReply.resolve("Mass fraction is a constituent mass divided by total mixture mass.", evidence: evidence)
        try check(!noCite.text.isEmpty && noCite.sources.isEmpty && noCite.sourceNote != nil, "An uncited explanation is readable and clearly unverified instead of discarded")
        let badCite = AssistantReply.resolve("A claimed definition [99].", evidence: evidence)
        try check(badCite.sources.isEmpty && badCite.sourceNote != nil, "Unknown references cannot receive linked-source presentation")
        let linked = AssistantReply.resolve("Current rises [1].", evidence: evidence)
        try check(linked.sources.count == 1 && linked.sourceNote == nil, "Only known document references receive source-linked presentation")
        let general = AssistantReply.resolve("General context: This explanation is not established by these passages.", evidence: evidence)
        try check(general.sources.isEmpty && general.sourceNote == nil, "Explicit general context stays separate from linked document claims")
        let model = DocumentAssistant()
        print("Availability:", model.availability)
        model.question = "What happens to electrode current when concentration rises?"
        if CommandLine.arguments.contains("--live"), model.checkAvailability() {
            let fixture = LibraryHit(path: "/fixture/Electrode.md", folderID: "fixture", page: 1, excerpt: "For this electrode, current increases as reactant concentration increases. The experiment held temperature and electrode area constant.", score: -1)
            let started = Date()
            model.ask(passages: [fixture.assistantPassage], topic: "electrode concentration")
            for _ in 0..<600 { if !model.working { break }; try await Task.sleep(for: .milliseconds(100)) }
            try check(!model.working && !model.answer.isEmpty && model.sources.count == 1, "On-device model produces a cited answer from the supplied fixture")
            try check(model.answer.localizedCaseInsensitiveContains("current"), "Live answer addresses the fixture question")
            try model.answer.write(to: output.appendingPathComponent("on-device-answer.txt"), atomically: true, encoding: .utf8)
            print("On-device response seconds:", Date().timeIntervalSince(started)); print(model.answer)
            let queries = try await SearchExpansion.plan(query: "What puts the brakes on ions reaching the electrode?", vocabulary: ["diffusion", "transport", "electrode", "current", "concentration", "boundary", "layer"])
            try check(!queries.isEmpty && queries.count <= 4, "On-device model translates an indirect request into a bounded retrieval plan")
            try JSONSerialization.data(withJSONObject: queries, options: .prettyPrinted).write(to: output.appendingPathComponent("exploration-plan.json"))
            let folder = output.appendingPathComponent("ExploreFixture", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# Electrode transport\nElectrode current is limited by diffusion through a boundary layer. Ion concentration controls transport.".write(to: folder.appendingPathComponent("Transport.md"), atomically: true, encoding: .utf8)
            let store = LibraryIndex(location: output.appendingPathComponent("exploration-\(UUID().uuidString).sqlite"))
            try await store.add(folder); try await store.refresh { _ in }
            let exact = try await store.search("What puts the brakes on ions reaching the electrode?")
            var related: [LibraryHit] = []
            for query in queries { related += try await store.search(query) }
            try check(exact.isEmpty && !related.isEmpty, "Indirect wording retrieves an indexed scientific passage through generated concepts")
            let mixture = LibraryHit(path: "/fixture/Mixture.pdf", folderID: "fixture", page: 4, excerpt: "Mass fraction Y_i is defined as constituent mass m_i divided by total mixture mass m: Y_i = m_i / m. It is dimensionless, lies between zero and one, and the mass fractions of all constituents sum to one.", score: -1)
            model.question = "what is the mass fraction?"
            model.ask(passages: [mixture.assistantPassage], topic: "mixtures", detail: .mid)
            for _ in 0..<900 { if !model.working { break }; try await Task.sleep(for: .milliseconds(100)) }
            try check(!model.working && !model.answer.isEmpty && model.message == nil, "The reported mass-fraction question returns a readable actual on-device answer")
            try check(!model.sources.isEmpty || model.turns.last?.sourceNote != nil || model.turns.last?.generalContext == true, "An answer always distinguishes linked, unverified and general sources")
            try model.answer.write(to: output.appendingPathComponent("mass-fraction-answer.txt"), atomically: true, encoding: .utf8)
            model.ask(passages: [fixture.assistantPassage], topic: "electrode"); model.clear()
            try await Task.sleep(for: .milliseconds(300))
            try check(!model.working && model.answer.isEmpty && model.sources.isEmpty, "Clearing cancels and hides stale generation")
        }
        model.clear(); model.ask(passages: [], topic: "empty")
        try check(!model.working && model.answer.isEmpty, "An empty result set cannot launch generation")
        print("Passed \(checks) assistant checks"); exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
