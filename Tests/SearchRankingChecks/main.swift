import SQLite3

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NSError(domain: "SearchRanking", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    checks += 1
}
func corpusCheck(_ root: String) throws {
    let folder = URL(fileURLWithPath: root)
    var db: OpaquePointer?
    guard sqlite3_open_v2(folder.deletingLastPathComponent().appendingPathComponent("2026-10-21-answer-evidence/corpus.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT heading,body FROM pages ORDER BY path,CAST(page AS INTEGER)", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    let ranker = SparseSearchRanker(), start = Date(); var row: Int64 = 0
    while sqlite3_step(statement) == SQLITE_ROW {
        let heading = String(cString: sqlite3_column_text(statement, 0)), body = String(cString: sqlite3_column_text(statement, 1))
        autoreleasepool { ranker.append(rowID: row, heading: heading, body: body) }; row += 1
    }
    try ranker.finish()
    print("Native build index", Date().timeIntervalSince(start), "pages", row)
    let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("results.json"))) as! [[String: Any]]
    let guided = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("guided-results.json"))) as! [[String: Any]]
    for query in baseline where query["split"] as? String != "control" {
        let text = query["query"] as! String, id = query["id"] as! String
        let models = query["models"] as! [String: [String: Any]], expected = models["B0"]!["raw"] as! [[String: Any]]
        let begin = Date(), matches = try ranker.search(text)
        try expect(Array(matches.prefix(10).map(\.rowID)) == expected.map { Int64($0["row"] as! Int) }, id + " B0 raw ten match frozen Python")
        let g = guided.first { $0["id"] as? String == id }!, plan = g["plan"] as! [String]
        let result = g["result"] as! [String: Any], raw = result["raw"] as! [[String: Any]]
        let expanded = try ranker.search(text, expansions: plan)
        try expect(Array(expanded.prefix(10).map(\.rowID)) == raw.map { Int64($0["row"] as! Int) }, id + " guided raw ten match frozen Python")
        print(id, "native B0 seconds", Date().timeIntervalSince(begin))
    }
}
do {
    try expect(SearchLexicon.words("Café naïve x2") == ["cafe", "naive", "x", "2"], "Fixed accent and digit tokenisation")
    try expect(SearchLexicon.terms("Why are gradients vanishing?") == ["gradient", "vanish"], "Frozen question stopwords and inflection")
    for query in ["sigmoid", "PISO", "\"linear system of equations\"", "gradient descent"] { try expect(!SearchLexicon.isQuestion(query), "Literal queries bypass model") }
    for query in ["Why does a coarse mesh smear a front?", "What is a sigmoid function?", "How do we conserve mass?", "Can pressure correct the velocity field?"] { try expect(SearchLexicon.isQuestion(query), "Question is eligible") }
    for offline in [true, false] {
        for enabled in [true, false] {
            for manual in [true, false] {
                try expect(SearchBoostPolicy.allows(query: "Why do gradients vanish?", enabled: enabled, offline: offline, manual: manual, deviceReady: true) == (enabled && !offline && !manual), "Policy keeps offline/Manual/disabled on B0")
            }
        }
    }
    try expect(!SearchBoostPolicy.allows(query: "Why do gradients vanish?", enabled: true, offline: false, manual: false, deviceReady: false), "Unavailable model leaves B0")
    let suite = UserDefaults(suiteName: "remile-search-checks-" + UUID().uuidString)!
    try expect(SearchBoostPolicy.enabled(defaults: suite), "Boosting defaults on without overwriting an explicit choice")
    suite.set(false, forKey: SearchBoostPolicy.preference); try expect(!SearchBoostPolicy.enabled(defaults: suite), "Explicit false is retained")
    try expect(SearchBoostPolicy.validate(["vanishing gradients", "VANISHING GRADIENTS", "x", "one two three four five six seven"]) == ["vanishing gradients"], "Plan validation bounds and deduplicates")
    let ranker = SparseSearchRanker()
    ranker.append(rowID: 1, heading: "Sigmoid", body: "The sigmoid activation is smooth and bounded. Binary classification predicts a probability.")
    ranker.append(rowID: 2, heading: "Pressure", body: "The pressure Poisson equation combines momentum and continuity to enforce mass conservation.")
    ranker.append(rowID: 3, heading: "Transport", body: "Coarse upwind discretisation introduces numerical diffusion and smears a transported front.")
    try ranker.finish()
    let partial = try ranker.search("sigmoid nonexistent")
    try expect(partial.first?.rowID == 1, "Unknown term does not remove partial lexical evidence")
    let pressure = try ranker.search("How does pressure enforce mass conservation?")
    try expect(pressure.first?.rowID == 2, "Question works without any AI")
    let restricted = try ranker.search("sigmoid pressure", allowed: [2])
    try expect(restricted.count == 1 && restricted.first?.rowID == 2, "Hard phrase candidates apply before rank fusion")
    let fused = try ranker.search("sharp front", expansions: ["numerical diffusion"])
    try expect(fused.first?.rowID == 3, "Independent expanded BM25 route reaches technical terminology")
    let missing = try ranker.search("zzxqv")
    try expect(missing.isEmpty, "No invented evidence for unknown vocabulary")
    if let root = CommandLine.arguments.dropFirst().first, !root.isEmpty { try corpusCheck(root) }
    print("PASS", checks, "search ranking checks")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
