import Foundation
import Combine

enum AssistantResponseDetail: String, CaseIterable {
    case low = "Low", mid = "Mid", high = "High"
    static let preference = "assistant.responseDetail"
    static func current(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preference) ?? "") ?? .mid
    }
    var maximumTokens: Int { switch self { case .low: 350; case .mid: 800; case .high: 1400 } }
    var cloudTokens: Int { switch self { case .low: 700; case .mid: 2400; case .high: 6000 } }
    var instruction: String {
        switch self {
        case .low: "Give a brief direct answer, usually one to three sentences."
        case .mid: "Explain the main points and supporting reasoning in a few paragraphs, Use only the length the question needs; a simple factual question needs one sentence."
        case .high: "Give a thorough explanation with evidence, reasoning and relevant limitations, Use detail only where it adds understanding; simple questions still need short answers. Use short sections or lists if they help."
        }
    }
}

struct AssistantEvidence: Identifiable, Sendable, Codable {
    let number: Int
    let location: AssistantLocation
    let text: String
    var id: Int { number }
    static func make(_ passages: [AssistantPassage], expanded: Bool = false) -> [AssistantEvidence] {
        var remaining = expanded ? 64_000 : 2600, seen = Set<String>(), result: [AssistantEvidence] = []
        for passage in passages where result.count < (expanded ? 12 : 6) && remaining > 100 {
            guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(passage.id).inserted else { continue }
            let text = bounded(passage.text, bytes: min(expanded ? 8000 : 650, remaining))
            remaining -= text.utf8.count
            result.append(AssistantEvidence(number: result.count + 1, location: passage.location, text: text))
        }
        return result
    }
    static func bounded(_ string: String, bytes: Int) -> String {
        var result = "", count = 0
        for character in string {
            let size = String(character).utf8.count
            guard count + size <= bytes else { break }
            result.append(character); count += size
        }
        return result
    }
    private static func citationNumbers(in answer: String) -> [Int]? {
        let pattern = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]")
        let text = answer as NSString
        var numbers: [Int] = []
        for match in pattern.matches(in: answer, range: NSRange(location: 0, length: text.length)) {
            let body = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard body.first?.isNumber == true else { continue }
            for item in body.split(separator: ",", omittingEmptySubsequences: false) {
                let bounds = item.components(separatedBy: CharacterSet(charactersIn: "-–—")).map { $0.trimmingCharacters(in: .whitespaces) }
                if bounds.count == 1, let number = Int(bounds[0]) { numbers.append(number) }
                else if bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]), lower > 0, upper >= lower, upper <= 12 {
                    numbers.append(contentsOf: lower...upper)
                } else { return nil }
            }
        }
        return numbers
    }
    static func citations(in answer: String, sources: [AssistantEvidence]) -> [AssistantEvidence]? {
        guard let numbers = citationNumbers(in: answer), !numbers.isEmpty,
              numbers.allSatisfy({ number in sources.contains { $0.number == number } }) else { return nil }
        return sources.filter { numbers.contains($0.number) }
    }
    static func hasGeneralContextLabel(_ answer: String) -> Bool {
        answer.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("General context:")
    }
    static func isGeneralContext(_ answer: String) -> Bool {
        hasGeneralContextLabel(answer) && citationNumbers(in: answer) == []
    }
}

struct AssistantReply {
    let text: String
    let sources: [AssistantEvidence]
    let sourceNote: String?
    static func resolve(_ text: String, evidence: [AssistantEvidence]) -> Self {
        if let cited = AssistantEvidence.citations(in: text, sources: evidence) {
            return Self(text: text, sources: cited, sourceNote: nil)
        }
        return Self(text: text, sources: [], sourceNote: AssistantEvidence.isGeneralContext(text) ? nil : "Sources not verified")
    }
}

struct AssistantTurn: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    let question: String
    var answer = ""
    var sources: [AssistantEvidence] = []
    var generalContext = false
    var status: String?
    var sourceNote: String?
}

@MainActor
final class DocumentAssistant: ObservableObject {
    @Published var question = ""
    @Published private(set) var turns: [AssistantTurn] = []
    @Published private(set) var answer = ""
    @Published private(set) var sources: [AssistantEvidence] = []
    @Published private(set) var working = false
    @Published private(set) var message: String?
    @Published private(set) var availability = ""
    @Published private(set) var stage = "Thinking…"
    @Published private(set) var progress: Double?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var historyKey: String?
    private var historyObserver: AnyCancellable?
    private var engine = AssistantEngine.onDevice
    func useEngine(_ engine: AssistantEngine) { cancel(); self.engine = engine; checkAvailability() }
    init(historyKey: String? = nil) {
        checkAvailability()
        self.historyKey = historyKey
        restoreHistory()
        historyObserver = NotificationCenter.default.publisher(for: AssistantHistory.changed).sink { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancel(persist: false)
                if notification.object as? Bool == true { self.turns = []; self.answer = ""; self.sources = []; self.question = "" }
                self.restoreHistory()
            }
        }
    }
    func useHistory(_ key: String?) {
        guard key != historyKey else { return }
        cancel(); historyKey = key; turns = []; answer = ""; sources = []; question = ""; restoreHistory()
    }
    private func restoreHistory() {
        guard let historyKey else { return }
        do {
            turns = try AssistantHistory.load()[historyKey] ?? []
            for index in turns.indices where turns[index].answer.isEmpty && turns[index].status == nil { turns[index].status = "Stopped" }
            answer = turns.last?.answer ?? ""; sources = turns.last?.sources ?? []
        } catch { message = "Unable to read Ask history." }
    }
    private func saveHistory() {
        guard let historyKey else { return }
        do { try AssistantHistory.save(turns, key: historyKey) }
        catch { message = "Unable to save Ask history." }
    }
    @discardableResult func checkAvailability() -> Bool {
        let retained = AssistantHistory.retained(["current": turns], days: AssistantHistoryRetention.current.rawValue)["current"] ?? []
        if retained.count != turns.count { turns = retained; answer = turns.last?.answer ?? ""; sources = turns.last?.sources ?? []; saveHistory() }
        let state = engine.status()
        availability = state.message; return state.ready
    }
    func cancel(persist: Bool = true) {
        let wasWorking = working
        if working, let last = turns.indices.last { turns[last].status = "Stopped" }
        task?.cancel(); task = nil; generation = UUID(); working = false; progress = nil; if persist && wasWorking { saveHistory() }
    }
    func clear() { cancel(); turns = []; answer = ""; sources = []; message = nil; question = ""; saveHistory() }
    func reportProgress(_ fraction: Double) {
        guard working, !Task.isCancelled else { return }
        progress = min(1, max(0, fraction))
    }
    // Prior replies help resolve follow-ups; they never become evidence for the next answer.
    var recentConversation: String {
        let history = turns.suffix(engine.expandedContext ? 8 : 2).map { turn in
            let reply = turn.answer.replacingOccurrences(of: "\\[[0-9][^\\]\\n]*\\]", with: "", options: .regularExpression)
            return "User: \(AssistantEvidence.bounded(turn.question, bytes: engine.expandedContext ? 2000 : 200))\nAssistant: \(AssistantEvidence.bounded(reply, bytes: engine.expandedContext ? 4000 : 250))"
        }.joined(separator: "\n")
        return AssistantEvidence.bounded(history, bytes: engine.expandedContext ? 20_000 : 900)
    }
    func ask(passages: [AssistantPassage], topic: String, detail: AssistantResponseDetail = .current()) {
        guard !passages.isEmpty else { message = "No readable passages."; return }
        ask(topic: topic, detail: detail) { _ in passages }
    }
    func ask(topic: String, detail: AssistantResponseDetail = .current(), retrieve: @escaping @MainActor (String) async throws -> [AssistantPassage]) {
        guard !working, checkAvailability() else { return }
        let draft = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let submitted = AssistantEvidence.bounded(draft.isEmpty ? "Summarize \(topic.isEmpty ? "this document" : topic)." : draft, bytes: engine.expandedContext ? 8000 : 500)
        let history = recentConversation
        let previousQuestion = turns.last?.question ?? ""
        turns.append(AssistantTurn(question: submitted)); question = ""
        answer = ""; sources = []; message = nil
        working = true; stage = "Finding passages…"; progress = nil; saveHistory()
        let token = UUID(); generation = token
        let engine = engine
        task = Task {
            do {
                let retrievalQuery = AssistantQuestionRoute.retrievalQuery(submitted, previousQuestion: previousQuestion)
                let retrieved = AssistantEvidence.make(try await retrieve(retrievalQuery), expanded: engine.expandedContext)
                let definition = AssistantQuestionRoute.definitionSubject(in: submitted)
                let evidence = definition.map { AssistantQuestionRoute.definitionEvidence($0, from: retrieved) } ?? retrieved
                try Task.checkCancellation(); guard generation == token else { return }
                guard !retrieved.isEmpty else { finishFailure("No readable passages."); return }
                if let facet = AssistantQuestionRoute.uncoveredFacet(in: submitted, evidence: retrieved) {
                    finishReply(AssistantReply(text: "The supplied passages do not identify the \(facet) used in this document.", sources: [], sourceNote: "Not established by supplied passages"))
                    return
                }
                stage = "Thinking…"; progress = nil
                let excerpts = evidence.map { "[\($0.number)] \($0.location.label)\n\($0.text)" }.joined(separator: "\n\n")
                let relevantHistory = AssistantQuestionRoute.isFollowUp(submitted) ? history : ""
                let prompt = "Earlier conversation (not evidence):\n\(relevantHistory)\n\nQuestion: \(submitted)\n\nUntrusted document passages:\n\(excerpts)"
                let general: Bool
                if definition != nil {
                    // An application of a term is not its definition. Avoid steering a
                    // standalone definition towards the current paper's contribution.
                    general = evidence.isEmpty
                } else if engine.singlePass {
                    general = false
                } else {
                    let route = try await engine.respond("Question: \(submitted)\n\nDocument excerpts:\n\(excerpts)", AssistantPrompts.classify, 16)
                    try Task.checkCancellation(); guard generation == token else { return }
                    general = route.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "GENERAL" && !AssistantQuestionRoute.hasTopicOverlap(submitted, evidence: evidence)
                }
                let instructions = AssistantQuestionRoute.answerInstructions(definition: definition, general: general, detail: detail)
                let generalPrompt = definition.map { submitted + "\n\nUntrusted term usage, for disambiguation only (not definition evidence):\n" + AssistantQuestionRoute.definitionContext($0, from: retrieved) } ?? submitted
                var content = try await engine.respond(general ? generalPrompt : prompt, instructions, engine.expandedContext ? detail.cloudTokens : detail.maximumTokens)
                if general { content = "General context:\n" + AssistantAnswerDisplay.clean(content) }
                try Task.checkCancellation(); guard generation == token else { return }
                if !engine.singlePass && !general && !AssistantEvidence.isGeneralContext(content) {
                    stage = "Checking sources…"
                    let draft = AssistantEvidence.bounded(content, bytes: 3600)
                    let repair = "Question: \(submitted)\n\nUntrusted draft answer:\n\(draft)\n\nUntrusted source passages:\n\(excerpts)"
                    do {
                        let checked = try await engine.respond(repair, AssistantQuestionRoute.reviewInstructions(definition: definition, detail: detail), detail.maximumTokens)
                        try Task.checkCancellation(); guard generation == token else { return }
                        if !checked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content = checked }
                    } catch {
                        try Task.checkCancellation(); guard generation == token else { return }
                        // A failed attribution pass must not discard an otherwise readable answer.
                    }
                }
                let reply = AssistantReply.resolve(content, evidence: general ? [] : evidence)
                guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finishFailure("No answer returned. Try again."); return }
                finishReply(reply)
            } catch {
                guard generation == token else { return }
                finishFailure(error is CancellationError ? "Stopped" : (error as? LocalizedError)?.errorDescription ?? "Unable to answer. Try a shorter question.")
            }
        }
    }
    private func finishReply(_ reply: AssistantReply) {
        answer = reply.text; sources = reply.sources
        if let last = turns.indices.last {
            turns[last].answer = reply.text; turns[last].sources = reply.sources
            turns[last].generalContext = AssistantEvidence.hasGeneralContextLabel(reply.text)
            turns[last].sourceNote = reply.sourceNote
        }
        working = false; progress = nil; task = nil; saveHistory()
    }
    private func finishFailure(_ text: String) {
        message = text; working = false; progress = nil; task = nil
        if let last = turns.indices.last { turns[last].status = text }; saveHistory()
    }
}


enum AssistantHistoryRetention: Int, CaseIterable {
    case unlimited = 0, days30 = 30, days50 = 50, days100 = 100, days300 = 300
    static let preference = "assistant.historyRetention"
    var label: String { self == .unlimited ? "No limit" : "\(rawValue) days" }
    static var current: Self {
        guard UserDefaults.standard.object(forKey: preference) != nil else { return .days30 }
        return Self(rawValue: UserDefaults.standard.integer(forKey: preference)) ?? .days30
    }
}

/// User conversation history only; unrelated to the document search index or model caches.
enum AssistantHistory {
    static let changed = Notification.Name("Remile.AskHistoryChanged")
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.remile.app/Ask/history.json")
    }
    static func retained(_ conversations: [String: [AssistantTurn]], days: Int, now: Date = Date()) -> [String: [AssistantTurn]] {
        guard days > 0 else { return conversations }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return conversations.mapValues { $0.filter { $0.createdAt >= cutoff } }.filter { !$0.value.isEmpty }
    }
    static func load(from location: URL = url, days: Int = AssistantHistoryRetention.current.rawValue) throws -> [String: [AssistantTurn]] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [:] }
        let original = try JSONDecoder().decode([String: [AssistantTurn]].self, from: Data(contentsOf: location))
        let result = retained(original, days: days)
        if result.values.reduce(0, { $0 + $1.count }) != original.values.reduce(0, { $0 + $1.count }) { try write(result, to: location) }
        return result
    }
    private static func write(_ conversations: [String: [AssistantTurn]], to location: URL) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(conversations).write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
    }
    static func save(_ turns: [AssistantTurn], key: String, to location: URL = url) throws {
        var conversations = try load(from: location)
        conversations[key] = turns.isEmpty ? nil : turns
        try write(retained(conversations, days: AssistantHistoryRetention.current.rawValue), to: location)
    }
    @MainActor static func clearAll() throws {
        try write([:], to: url)
        NotificationCenter.default.post(name: changed, object: true)
    }
    @MainActor static func applyRetention() throws {
        _ = try load()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}


enum AssistantAnswerDisplay {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "(?im)^[ \\t]*(?:\\*\\*)?General context:(?:\\*\\*)?[ \\t]*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


enum AssistantQuestionRoute {
    /// Carry context into retrieval only for a follow-up. Otherwise an earlier topic
    /// can outrank the user's new question before generation even starts.
    static func retrievalQuery(_ question: String, previousQuestion: String) -> String {
        AssistantEvidence.bounded(question + (isFollowUp(question) ? "\n" + previousQuestion : ""), bytes: 1000)
    }
    static func isFollowUp(_ question: String) -> Bool {
        let text = question.lowercased()
        return text.range(of: "\\b(it|its|that|those|these|they|their|them|above|again)\\b|^(and |why\\??$|how so|tell me more|explain more|which quantities)", options: .regularExpression) != nil
    }
    /// Recognise self-contained definition requests before a model sees retrieved
    /// research passages. Document-specific and deictic questions keep normal routing.
    static func definitionSubject(in question: String) -> String? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !isFollowUp(text), lower.range(of: "\\b(paper|document|study|authors?|article|experiment|passages?|according|reported|proposed|used)\\b", options: .regularExpression) == nil else { return nil }
        let patterns = ["(?i)^(?:what (?:is|are)|define|what does)\\s+(?:(?:the|a|an)\\s+)?(.+?)(?:\\s+(?:mean|stand for))?[?.!]*$", "^(.+?)(?:이란|란|의 뜻)(?:\\s*(?:무엇|뭐|알려).*)?[?.!]*$"]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern), source = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { continue }
            let subject = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Conjunctive/problem questions need the ordinary document route.
            guard !subject.isEmpty, subject.count <= 100, subject.split(whereSeparator: \.isWhitespace).count <= 10,
                  subject.range(of: "(?i)\\b(and|when|why|how|happens?|difference|between|best|better|most|in|for|with)\\b", options: .regularExpression) == nil else { return nil }
            return subject
        }
        return nil
    }
    static func definitionEvidence(_ subject: String, from sources: [AssistantEvidence]) -> [AssistantEvidence] {
        func normalise(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let acronym = subject.hasSuffix("s") && subject.dropLast().allSatisfy(\.isUppercase) ? String(subject.dropLast()) : subject
        let term = NSRegularExpression.escapedPattern(for: normalise(acronym)).replacingOccurrences(of: " ", with: "\\s+")
        guard !term.isEmpty else { return [] }
        // Conservative local support: a nearby copula/definition/expansion, not just
        // a paper mentioning an acronym. This does not verify semantic entailment.
        let patterns = ["(?:^|\\s)\(term)s?\\s+(?:(?:is|are)\\s+(?:(?:a|an|the)\\s+|defined\\s+as\\s+)|(?:means?|denotes?|refers? to|stands? for|can be defined as)\\s+)", "\\b(?:define|defined|definition of)\\s+(?:the\\s+)?\(term)s?\\b"]
        return sources.compactMap { source in
            let sentences = source.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            let definitions = sentences.filter { sentence in
                let text = normalise(sentence)
                if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
                guard acronym.count >= 2, acronym.count <= 8, acronym.allSatisfy({ $0.isASCII && $0.isLetter }),
                      let range = sentence.range(of: "\\(\\s*\(NSRegularExpression.escapedPattern(for: acronym))s?\\s*\\)", options: [.regularExpression, .caseInsensitive]) else { return false }
                let initials = normalise(String(sentence[..<range.lowerBound])).split(separator: " ").compactMap(\.first)
                return String(initials.suffix(acronym.count)) == acronym.lowercased()
            }
            guard !definitions.isEmpty else { return nil }
            return AssistantEvidence(number: source.number, location: source.location, text: AssistantEvidence.bounded(definitions.joined(separator: ". ").trimmingCharacters(in: .whitespaces), bytes: 650))
        }
    }
    static func definitionContext(_ subject: String, from sources: [AssistantEvidence]) -> String {
        let term = NSRegularExpression.escapedPattern(for: subject)
        let snippets = sources.compactMap { source -> String? in
            let sentences = source.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            guard let sentence = sentences.first(where: { $0.range(of: "(?<![\\p{L}\\p{N}])\(term)s?(?![\\p{L}\\p{N}])", options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
            // A short usage clause disambiguates acronyms without feeding a paper's
            // subsequent result/conclusion into a standalone definition response.
            let clause = sentence.components(separatedBy: " and ").first ?? sentence
            return AssistantEvidence.bounded(clause.trimmingCharacters(in: .whitespaces), bytes: 220)
        }
        return AssistantEvidence.bounded(snippets.prefix(2).joined(separator: "\n"), bytes: 400)
    }
    /// A named requested facet must occur in the supplied material before a nearby
    /// but different methodology can answer it. This deliberately conservative
    /// lexical guard does not claim the entire document lacks that information.
    static func uncoveredFacet(in question: String, evidence: [AssistantEvidence]) -> String? {
        let pattern = "(?i)^(?:what|which)\\s+([\\p{L}]+(?:[ -]+[\\p{L}]+){0,3}?)\\s+(model|method|solver|closure|mechanism|scheme|equations?)\\b"
        let regex = try! NSRegularExpression(pattern: pattern), source = question as NSString
        guard let match = regex.firstMatch(in: question, range: NSRange(location: 0, length: source.length)) else { return nil }
        let qualifier = source.substring(with: match.range(at: 1)).lowercased()
        let words = qualifier.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let deictic: Set<String> = ["is", "are", "the", "a", "an", "this", "that", "their", "its", "kind", "type", "of", "specific"]
        guard !words.isEmpty, words.allSatisfy({ !deictic.contains($0) }) else { return nil }
        let text = evidence.map(\.text).joined(separator: " ").lowercased()
        guard words.contains(where: { word in text.range(of: "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}])", options: .regularExpression) == nil }) else { return nil }
        return qualifier + " " + source.substring(with: match.range(at: 2)).lowercased()
    }
    static func answerInstructions(definition: String?, general: Bool, detail: AssistantResponseDetail) -> String { AssistantPrompts.answerInstructions(definition: definition, general: general, detail: detail) }
    static func reviewInstructions(definition: String?, detail: AssistantResponseDetail) -> String { AssistantPrompts.reviewInstructions(definition: definition, detail: detail) }
    /// A new analogy can still be about the supplied material. Never let the router
    /// discard that material merely because the comparison is not literally present.
    static func hasTopicOverlap(_ question: String, evidence: [AssistantEvidence]) -> Bool {
        let ignored: Set<String> = ["what", "which", "when", "where", "does", "have", "that", "this", "these", "those", "with", "from", "their", "there", "about", "explain", "please", "document", "passages", "passage", "answer", "general", "knowledge", "would", "could", "should", "because", "give", "brief", "context"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 && !ignored.contains($0) })
        }
        return !words(question).isDisjoint(with: words(evidence.map(\.text).joined(separator: " ")))
    }
}
