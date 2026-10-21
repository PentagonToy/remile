import Foundation

/// Fixed lexical rules shared by sparse ranking and query-only expansion validation.
enum SearchLexicon {
    private static let expression = try! NSRegularExpression(pattern: "[a-z]+|[0-9]+")
    // Fixed scikit-learn English word list; BSD notice in others/licences/SEARCH-WORDS.txt.
    private static let stop = Set("a about above across after afterwards again against all almost alone along already also although always am among amongst amoungst amount an and another any anyhow anyone anything anyway anywhere are around as at back be became because become becomes becoming been before beforehand behind being below beside besides between beyond bill both bottom but by call can cannot cant co con could couldnt cry de describe detail do done down due during each eg eight either eleven else elsewhere empty enough etc even ever every everyone everything everywhere except explain few fifteen fifty fill find fire first five for former formerly forty found four from front full further get give go had has hasnt have he hence her here hereafter hereby herein hereupon hers herself him himself his how however hundred i ie if in inc indeed interest into is it its itself keep last latter latterly least less ltd made many may me meanwhile might mill mine more moreover most mostly move much must my myself name namely neither never nevertheless next nine no nobody none noone nor not nothing now nowhere of off often on once one only onto or other others otherwise our ours ourselves out over own part per perhaps please put rather re reason same see seem seemed seeming seems serious several she should show side since sincere six sixty so some somehow someone something sometime sometimes somewhere still such system take ten than that the their them themselves then thence there thereafter thereby therefore therein thereupon these they thick thin third this those though three through throughout thru thus to together too top toward towards twelve twenty two un under until up upon us use used using very via was we well were what whatever when whence whenever where whereafter whereas whereby wherein whereupon wherever whether which while whither who whoever whole whom whose why will with within without would yet you your yours yourself yourselves".split(separator: " ").map(String.init))
    private static let stoppedStems = Set(stop.map(stem))
    static func words(_ text: String) -> [String] {
        let ascii = String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.isASCII })).lowercased()
        let source = ascii as NSString
        return expression.matches(in: ascii, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }
    static func stem(_ word: String) -> String {
        var w = word
        if w.count > 5 && w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
        else if w.count > 4 && w.hasSuffix("s") && !["ss", "us", "is"].contains(where: w.hasSuffix) { w.removeLast() }
        if w.count > 6 && w.hasSuffix("ing") {
            w = String(w.dropLast(3)); w = undouble(w)
        } else if w.count > 5 && w.hasSuffix("ed") {
            w = String(w.dropLast(2)); w = undouble(w)
        }
        if w.count > 4 && w.hasSuffix("e") && !w.hasSuffix("ee") { w.removeLast() }
        return w
    }
    private static func undouble(_ word: String) -> String {
        let tail = word.suffix(2)
        if word.count > 2, tail.first == tail.last, let last = tail.last, last != "s", last != "f" { return String(word.dropLast()) }
        return word
    }
    static func terms(_ text: String) -> [String] {
        words(text).filter { !stop.contains($0) }.map(stem).filter { !stoppedStems.contains($0) }
    }
    static func canonical(_ text: String) -> String { words(text).joined(separator: " ") }
    static func matchedQuery(_ body: String, query: String) -> String {
        if query.contains("\"") { return query }
        let wanted = Set(terms(query)); var seen = Set<String>()
        return words(body).filter { wanted.contains(stem($0)) && seen.insert($0).inserted }.prefix(24).joined(separator: " ")
    }
    static func isQuestion(_ query: String) -> Bool {
        guard !query.contains("\""), let first = words(query).first, terms(query).count >= 2 else { return false }
        return ["what", "why", "how", "when", "where", "which", "can", "could", "does", "do", "is", "are", "should", "would", "explain", "describe"].contains(first)
    }
}
