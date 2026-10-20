import AppKit
import CoreText
import PDFKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw NSError(domain: "ReaderAssistantChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    checks += 1
}
func makePDF() -> Data {
    let bytes = NSMutableData()
    let consumer = CGDataConsumer(data: bytes)!
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let graphics = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for number in 1...12 {
        graphics.beginPDFPage(nil)
        let lines = number == 9 ? ["Electrode experiment", "Reactant concentration controls electrode current.", "Current rises when concentration increases.", "Temperature and electrode area remain constant."] : ["Chapter \(number)", "This section describes unrelated laboratory equipment."]
        var y = 720.0
        for line in lines {
            graphics.textPosition = CGPoint(x: 44, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 15)])), graphics)
            y -= 32
        }
        graphics.endPDFPage()
    }
    graphics.closePDF()
    return bytes as Data
}
Task { @MainActor in
    do {
        let bytes = makePDF(), context = PDFAssistantContext(), path = "/fixture/Experiment.pdf"
        try bytes.write(to: output.appendingPathComponent("experiment.pdf"))
        let passages = try await context.passages(data: bytes, password: "", path: path, question: "How does concentration affect electrode current?", currentPage: 1, selection: nil) { _ in }
        try check(passages.first?.location.unit == 9, "Question retrieves the relevant page beyond the initial pages")
        try check(passages.count <= 6 && passages.allSatisfy { $0.text.utf8.count <= 650 }, "Retained passages are bounded")
        try check(passages.allSatisfy { $0.location.path == path }, "Sources remain scoped to this PDF")
        let misspelt = try await context.passages(data: bytes, password: "", path: path, question: "concentraton", currentPage: 1, selection: nil) { _ in }
        try check(misspelt.first?.location.unit == 9, "A one-letter typo still finds the experiment page")
        let summary = try await context.passages(data: bytes, password: "", path: path, question: "Summarize this PDF", currentPage: 5, selection: nil) { _ in }
        try check(summary.first?.location.unit == 5, "A broad question retains current-page context")
        let selected = try await context.passages(data: bytes, password: "", path: path, question: "current", currentPage: 1, selection: (3, "A specifically selected passage.")) { _ in }
        try check(selected.first?.location.unit == 3 && selected.first?.text.contains("selected") == true, "Explicit selection precedes retrieval candidates")
        let late = String(repeating: "Unrelated preface. ", count: 180) + "Current rises when concentration increases."
        try check(PDFAssistantContext.excerpt(late, terms: ["concentration"]).contains("concentration"), "A late keyword in a long paragraph survives evidence clipping")
        let encrypted = PDFDocument(data: bytes)!.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!
        do {
            _ = try await context.passages(data: encrypted, password: "", path: path, question: "current", currentPage: 1, selection: nil) { _ in }
            throw NSError(domain: "Locked PDF was read", code: 1)
        } catch PDFAssistantContext.Failure.restricted { checks += 1 }
        let unlocked = try await context.passages(data: encrypted, password: "reader", path: path, question: "current", currentPage: 1, selection: nil) { _ in }
        try check(unlocked.first?.location.unit == 9, "An explicitly unlocked, copyable PDF can supply passages")
        let cancelled = Task { try await context.passages(data: bytes, password: "", path: path, question: "current", currentPage: 1, selection: nil) { _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "Cancelled extraction completed", code: 2) }
        catch is CancellationError { checks += 1 }
        try check(AssistantEvidence.isGeneralContext("General context: These passages do not establish the answer."), "Explicitly qualified non-document replies can be displayed")
        try check(!AssistantEvidence.isGeneralContext("General context: Invented source [99]."), "General-context mode cannot bypass numeric source validation")
        try check(AssistantEvidence.citations(in: "A range [1–2].", sources: AssistantEvidence.make(passages))?.count == 2, "Common numeric citation ranges resolve to supplied pages")
        try check(AssistantEvidence.citations(in: "Invalid range [1–99].", sources: AssistantEvidence.make(passages)) == nil, "Out-of-bounds citation ranges are rejected")
        let defaults = UserDefaults(suiteName: "RemileChecks-\(UUID().uuidString)")!
        try check(AssistantResponseDetail.current(in: defaults) == .mid, "Response detail defaults to Mid")
        defaults.set("High", forKey: AssistantResponseDetail.preference)
        try check(AssistantResponseDetail.current(in: defaults) == .high, "Response detail persists independently of conversation state")
        defaults.removeObject(forKey: AssistantResponseDetail.preference)
        try check(AssistantResponseDetail.low.maximumTokens < AssistantResponseDetail.mid.maximumTokens && AssistantResponseDetail.mid.maximumTokens < AssistantResponseDetail.high.maximumTokens, "All three response settings have increasing generation budgets")
        let quote = AssistantCitation(location: passages[0].location, text: "… café concentration controls current …")
        let source = "Prefix 😀. CAFE\n concentration  controls current. Other words."
        let ranges = quote.ranges(in: source)
        try check(ranges.count == 1 && (source as NSString).substring(with: ranges[0]).contains("CAFE"), "Citation ranges preserve Unicode offsets across accents and line breaks")
        try check(quote.ranges(in: "Concentration appears here but this is a different claim.").isEmpty, "An unrelated keyword cannot become a citation highlight")
        let clipped = AssistantCitation(location: passages[0].location, text: "… oncentration controls current in the electrode experimen")
        try check(!clipped.ranges(in: "Concentration controls current in the electrode experiment.").isEmpty, "Clipped edge words still resolve a substantial contiguous excerpt")
        let bothEdges = AssistantCitation(location: passages[0].location, text: "… lane contours of temperature and heat release in a co …")
        try check(!bothEdges.ranges(in: "The cutplane contours of temperature and heat release in a color spectrum.").isEmpty, "Both excerpt edges may end inside short word fragments")
        try check(bothEdges.ranges(in: "The cutplane contours of pressure and heat release in a color spectrum.").isEmpty, "Clipped edges never excuse a changed word inside the passage")
        let equation = AssistantCitation(location: passages[0].location, text: "The result is x + y at the electrode surface.")
        try check(equation.ranges(in: "The result is x - y at the electrode surface.").isEmpty, "Changed mathematical operators cannot masquerade as the cited passage")
        try check(AssistantQuestionRoute.hasTopicOverlap("Is concentration like a tap?", evidence: AssistantEvidence.make(passages)), "A metaphor about the source topic keeps its document evidence")
        try check(!AssistantQuestionRoute.hasTopicOverlap("What is the capital of France?", evidence: AssistantEvidence.make(passages)), "An unrelated question has no artificial document-topic overlap")
        try check(AssistantQuestionRoute.definitionSubject(in: "what is the PINN?") == "PINN", "A standalone acronym question requests a definition before document routing")
        try check(AssistantQuestionRoute.definitionSubject(in: "What does PINN stand for?") == "PINN", "Acronym expansion requests retain the requested term")
        try check(AssistantQuestionRoute.definitionSubject(in: "Define a physics-informed neural network.") == "physics-informed neural network", "Multiword technical terms remain intact")
        try check(AssistantQuestionRoute.definitionSubject(in: "What is the PINN used in this paper?") == nil, "A paper-specific question retains its document contract")
        try check(AssistantQuestionRoute.definitionSubject(in: "What happens to current when concentration rises?") == nil, "A causal question is not mistaken for a term definition")
        try check(AssistantQuestionRoute.definitionSubject(in: "What is it?") == nil, "A deictic follow-up needs its previous context")
        try check(AssistantQuestionRoute.retrievalQuery("What is PINN?", previousQuestion: "Combustion modelling results") == "What is PINN?", "A fresh question does not inherit unrelated retrieval terms")
        try check(AssistantQuestionRoute.retrievalQuery("How does that work?", previousQuestion: "PINN") == "How does that work?\nPINN", "An actual follow-up retains useful retrieval context")
        let applied = AssistantEvidence(number: 1, location: passages[0].location, text: "PINN is applied to the flow problem. The proposed model improves its prediction error.")
        let defined = AssistantEvidence(number: 2, location: passages[0].location, text: "Physics-informed neural networks (PINNs) incorporate physical equations into training. The paper reports an unrelated result.")
        try check(AssistantQuestionRoute.definitionEvidence("PINN", from: [applied]).isEmpty, "A term's application does not count as definitional evidence")
        let property = AssistantEvidence(number: 1, location: passages[0].location, text: "PINN is accurate on this benchmark. Mass fraction is dimensionless.")
        try check(AssistantQuestionRoute.definitionEvidence("PINN", from: [property]).isEmpty && AssistantQuestionRoute.definitionEvidence("mass fraction", from: [property]).isEmpty, "A reported property is not substituted for a definition")
        let definitionSources = AssistantQuestionRoute.definitionEvidence("PINN", from: [applied, defined])
        try check(definitionSources.count == 1 && definitionSources[0].number == 2 && !definitionSources[0].text.contains("unrelated result"), "A definition keeps its real source identifier and omits unrelated paper results")
        try check(AssistantQuestionRoute.definitionEvidence("pinn", from: [defined]).count == 1 && AssistantQuestionRoute.definitionEvidence("PINNs", from: [defined]).count == 1, "Lowercase questions and plural acronyms still match explicit expansions")
        let massDefinition = AssistantEvidence(number: 3, location: passages[0].location, text: "Mass fraction is defined as a constituent mass divided by the total mixture mass.")
        try check(AssistantQuestionRoute.definitionEvidence("mass fraction", from: [massDefinition]).count == 1, "An explicit multiword definition keeps document support")
        let accidental = AssistantEvidence(number: 4, location: passages[0].location, text: "We evaluate our numerical solver (PINN) on a benchmark.")
        try check(AssistantQuestionRoute.definitionEvidence("PINN", from: [accidental]).isEmpty, "An arbitrary parenthesised acronym is not an established expansion")
        let usage = AssistantEvidence(number: 5, location: passages[0].location, text: "The proposed PINN is applied to a flow problem and achieves a smaller prediction error on the benchmark.")
        try check(AssistantQuestionRoute.definitionContext("pinn", from: [usage]) == "The proposed PINN is applied to a flow problem", "A short term-usage hint disambiguates an acronym without carrying later research outcomes")
        let turbulence = AssistantEvidence(number: 1, location: passages[0].location, text: "The model uses a standard k-epsilon turbulence closure for unresolved stresses.")
        try check(AssistantQuestionRoute.uncoveredFacet(in: "What combustion model does this paper use?", evidence: [turbulence]) == "combustion model", "A related turbulence method cannot substitute for an unsupported combustion model")
        try check(AssistantQuestionRoute.uncoveredFacet(in: "Which turbulence closure does the paper use?", evidence: [turbulence]) == nil, "A named facet present in the evidence keeps normal generation")
        try check(AssistantQuestionRoute.uncoveredFacet(in: "Which radiation model is used?", evidence: [turbulence]) == "radiation model", "The evidence-coverage guard works for other model categories")
        try check(AssistantQuestionRoute.uncoveredFacet(in: "What is a combustion model?", evidence: [turbulence]) == nil, "A general definition is not rejected as a document-method request")
        let historyURL = output.appendingPathComponent("history-fixture.json")
        var oldTurn = AssistantTurn(question: "Old question")
        oldTurn.createdAt = Date().addingTimeInterval(-60 * 86400)
        var freshTurn = AssistantTurn(question: "Current question")
        freshTurn.answer = "Current answer [1]."; freshTurn.sources = AssistantEvidence.make(passages)
        let stored = ["search": [oldTurn, freshTurn], "pdf:fixture": [freshTurn]]
        try check(AssistantHistory.retained(stored, days: 30)["search"]?.count == 1, "Retention expires individual old turns")
        try check(AssistantHistory.retained(stored, days: 0)["search"]?.count == 2, "No limit retains old history")
        try check(AssistantHistory.retained(stored, days: 100)["search"]?.count == 2, "Longer retention preserves eligible history")
        try AssistantHistory.save([freshTurn], key: "search", to: historyURL)
        try AssistantHistory.save([freshTurn], key: "pdf:fixture", to: historyURL)
        let reloaded = try AssistantHistory.load(from: historyURL)
        try check(reloaded["search"]?.first?.id == freshTurn.id && reloaded["pdf:fixture"]?.first?.sources.first?.text == freshTurn.sources.first?.text, "Local history round-trips identity and actual source excerpts in separate scopes")
        try AssistantHistory.save([], key: "search", to: historyURL)
        let afterClear = try AssistantHistory.load(from: historyURL)
        try check(afterClear["search"] == nil && afterClear["pdf:fixture"]?.count == 1, "Clear removes only the current conversation")
        try check(AssistantAnswerDisplay.clean("General context: Paris.\n\n**General context:** More detail.") == "Paris.\n\nMore detail.", "Classification labels are removed from displayed/copied prose")
        let assistant = DocumentAssistant()
        if CommandLine.arguments.contains("--live-quality"), assistant.checkAvailability() {
            let cases: [(String, String, String)] = [
                ("definition-with-application", "what is the pinn?", "The proposed PINN is applied to a flow problem and achieves a smaller prediction error on the benchmark."),
                ("definition-with-source", "What is PINN?", "Physics-informed neural networks (PINNs) are neural networks trained with a loss that penalises violations of physical equations."),
                ("unsupported-combustion", "What combustion model does this paper use?", "The model uses a standard k-epsilon turbulence closure to represent unresolved turbulent stresses. A passive scalar is transported.")
            ]
            for (name, question, text) in cases {
                assistant.clear(); assistant.question = question
                let started = Date()
                assistant.ask(passages: [AssistantPassage(location: AssistantLocation(path: "/fixture/Quality.md", unit: 1, label: "Section 1"), text: text)], topic: "quality fixture", detail: .low)
                for _ in 0..<900 { if !assistant.working { break }; try await Task.sleep(for: .milliseconds(100)) }
                let transcript = "Question: \(question)\nPassage: \(text)\nElapsed seconds: \(Date().timeIntervalSince(started))\nAnswer: \(assistant.answer)\nSources: \(assistant.sources.map(\.number))\nGeneral: \(assistant.turns.last?.generalContext == true)\n"
                try transcript.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                print(transcript)
                try check(!assistant.working && !assistant.answer.isEmpty && assistant.message == nil, "Live quality fixture returns a complete answer: \(name)")
                let response = assistant.answer.lowercased()
                if name.hasPrefix("definition") {
                    try check(response.contains("physics") && response.contains("neural"), "A PINN definition explains the requested term: \(name)")
                    try check(!response.contains("benchmark") && !response.contains("prediction error"), "A definition does not substitute a paper result: \(name)")
                    try check(name == "definition-with-source" ? !assistant.sources.isEmpty : assistant.turns.last?.generalContext == true, "Definition support is attributed accurately: \(name)")
                } else {
                    try check(response.range(of: "not (?:specified|provided|established|described|identify|state|mention)|does(?:n.t| not)|cannot|no combustion|not.*combustion", options: .regularExpression) != nil, "Unsupported combustion details are not invented")
                }

            }
            assistant.clear()
        }
        if CommandLine.arguments.contains("--live"), assistant.checkAvailability() {
            assistant.question = "What happens to electrode current when concentration increases?"
            assistant.ask(topic: "Experiment") { question in
                try await context.passages(data: bytes, password: "", path: path, question: question, currentPage: 1, selection: nil) { fraction in await assistant.reportProgress(fraction) }
            }
            for _ in 0..<600 { if !assistant.working { break }; try await Task.sleep(for: .milliseconds(100)) }
            try check(!assistant.answer.isEmpty && assistant.sources.contains { $0.location.unit == 9 }, "Actual on-device answer cites the retrieved PDF page")
            let first = assistant.turns.first!
            assistant.question = "Which quantities were kept constant in that experiment?"
            assistant.ask(topic: "Experiment") { question in
                try await context.passages(data: bytes, password: "", path: path, question: question, currentPage: 1, selection: nil) { _ in }
            }
            for _ in 0..<600 { if !assistant.working { break }; try await Task.sleep(for: .milliseconds(100)) }
            try check(assistant.turns.count == 2 && !assistant.answer.isEmpty && assistant.answer.localizedCaseInsensitiveContains("temperature"), "A second message uses conversation context and fresh PDF evidence")
            try check(assistant.turns.first?.id == first.id && assistant.turns.first?.sources.first?.location == first.sources.first?.location, "Earlier message sources remain stable across turns")
            try check(assistant.recentConversation.utf8.count <= 900 && !assistant.recentConversation.contains("[1]"), "Conversation context is bounded and strips obsolete citation numbers")
            assistant.question = "What is the capital of France? If the passages do not establish it, give general context and say so."
            assistant.ask(passages: passages, topic: "Experiment")
            for _ in 0..<600 { if !assistant.working { break }; try await Task.sleep(for: .milliseconds(100)) }
            print("Outside reply:", assistant.answer, "status:", assistant.message ?? "none")
            try check(assistant.turns.last?.generalContext == true && assistant.sources.allSatisfy { source in passages.contains { $0.location == source.location } }, "Outside knowledge is explicitly qualified and any PDF references resolve to supplied pages")
            let transcript = assistant.turns.map { "You: \($0.question)\nAsk: \($0.answer)\nSources: \($0.sources.map { $0.location.label }.joined(separator: ", "))" }.joined(separator: "\n\n")
            try transcript.write(to: output.appendingPathComponent("live-conversation.txt"), atomically: true, encoding: .utf8)
            assistant.question = "Explain again"; assistant.ask(passages: passages, topic: "Experiment"); assistant.cancel()
            try await Task.sleep(for: .milliseconds(300))
            try check(!assistant.working && assistant.turns.last?.status == "Stopped" && assistant.turns.last?.answer.isEmpty == true, "Stopped generation cannot append a late answer")
            assistant.clear()
            try check(assistant.turns.isEmpty && assistant.question.isEmpty && assistant.sources.isEmpty, "New document/conversation clears draft, turns and sources")
        }
        print("Passed \(checks) reader assistant checks"); exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
