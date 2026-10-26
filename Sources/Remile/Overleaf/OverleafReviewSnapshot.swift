import Foundation

/// Server ranges are UTF-16 offsets into the document returned with those ranges.
/// Keep that snapshot so a later local edit cannot silently move an anchor.
struct OverleafReviewSnapshot {
    struct Anchor {
        let file: String
        let source: String
        let version: Int?
        let offset: Int
        let length: Int
        var documentID: String? = nil
        var localPathKnown = true
        var line: Int { (source as NSString).substring(to: offset).filter { $0 == "\n" }.count }
        func location(in buffers: [String: String]) -> TeXSync.SourceLocation? {
            guard localPathKnown, buffers[file] == source else { return nil }
            return .init(file: file, line: line, range: NSRange(location: offset, length: length))
        }
    }
    struct Change: Identifiable {
        let id: String
        let documentID: String
        let changeID: String
        let insertion: Bool
        let text: String
        let anchor: Anchor
        let timestamp: String?
        var singleRange = true
        func rejectedSource() throws -> String {
            guard singleRange else { throw OverleafGit.Failure("Review this grouped change in Overleaf.") }
            let range = NSRange(location: anchor.offset, length: insertion ? (text as NSString).length : 0)
            guard let bounds = Range(range, in: anchor.source), !insertion || String(anchor.source[bounds]) == text else { throw OverleafGit.Failure("This change moved. Refresh the review.") }
            var source = anchor.source
            source.replaceSubrange(bounds, with: insertion ? "" : text)
            return source
        }
        func isCurrent(in data: Data) throws -> Bool {
            guard let document = try OverleafReviewSnapshot.documentRanges(data).first(where: { $0.id == documentID }) else { return false }
            let rows = document.ranges["changes"] as? [[String: Any]] ?? []
            let matches = rows.filter { $0["id"] as? String == changeID }
            guard singleRange, matches.count == 1, let op = matches[0]["op"] as? [String: Any], op["p"] as? Int == anchor.offset,
                  op[insertion ? "i" : "d"] as? String == text, op[insertion ? "d" : "i"] == nil else { return false }
            if !insertion {
                let sameDeletion = rows.filter { row in
                    guard let other = row["op"] as? [String: Any] else { return false }
                    return other["p"] as? Int == anchor.offset && other["d"] as? String == text
                }
                guard sameDeletion.count == 1 else { return false }
            }
            return true
        }
    }
    let archive: OverleafThreadArchive
    var anchors: [String: Anchor] = [:]
    var changes: [Change] = []
    var warning: String?
    var main: String?
    var needsConnection = false
    let observedAt = Date()

    static func documentRanges(_ data: Data) throws -> [(id: String, ranges: [String: Any])] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let rows = value as? [[String: Any]] ?? (value as? [String: Any])?["docs"] as? [[String: Any]], rows.count <= 2000 else { throw OverleafGit.Failure("The server returned an unfamiliar review format.") }
        var documents: [String: [String: Any]] = [:]
        for row in rows {
            guard let id = row["id"] as? String, validID(id), let ranges = row["ranges"] as? [String: Any] else { throw OverleafGit.Failure("The server returned an unfamiliar review format.") }
            if !(ranges["comments"] as? [Any] ?? []).isEmpty || !(ranges["changes"] as? [Any] ?? []).isEmpty { documents[id] = ranges }
        }
        guard documents.count <= 64 else { throw OverleafGit.Failure("This project has too many review files. Open it in Overleaf.") }
        return documents.keys.sorted().map { ($0, documents[$0]!) }
    }
    static func documents(_ data: Data) throws -> [String] { try documentRanges(data).map(\.id) }
    static func fingerprint(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: documentRanges(data).map { ["id": $0.id, "ranges": $0.ranges] }, options: [.sortedKeys])
    }
    mutating func includeDownload(_ data: Data, ranges: [String: Any], documentID: String, paths: [String]) throws {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let source = value["text"] as? String,
              let disposition = value["disposition"] as? String else { throw OverleafGit.Failure("The review source could not be read.") }
        func capture(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = expression.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)), let range = Range(match.range(at: 1), in: disposition) else { return nil }
            return String(disposition[range])
        }
        guard let name = capture(#"filename\*=UTF-8''([^;]+)"#)?.removingPercentEncoding ?? capture(#"filename="([^"]+)""#) ?? capture(#"filename=([^;]+)"#)?.trimmingCharacters(in: .whitespaces) else { throw OverleafGit.Failure("The review source filename is unavailable.") }
        let matches = paths.filter { $0 == name || ($0 as NSString).lastPathComponent == name }
        // A download names its document, not its containing folder. Only a
        // unique project path is safe to use for source navigation.
        if matches.count != 1 { warning = "Some review files could not be matched to local source." }
        let payload = try JSONSerialization.data(withJSONObject: ["pathname": matches.count == 1 ? matches[0] : name, "lines": source.components(separatedBy: "\n"), "ranges": ranges])
        try include(payload, documentID: documentID, localPathKnown: matches.count == 1)
    }
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }

    mutating func include(_ data: Data, documentID: String, localPathKnown: Bool = true) throws {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = value["lines"] as? [String], let rawPath = value["pathname"] as? String,
              let ranges = value["ranges"] as? [String: Any] else { throw OverleafGit.Failure("The server returned an unfamiliar review format.") }
        let file = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        guard !file.isEmpty, file.utf8.count < 4096, !file.contains("\\"), !file.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), file.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw OverleafGit.Failure("The server returned an unfamiliar review format.") }
        let source = lines.joined(separator: "\n"), text = source as NSString
        func anchor(_ operation: [String: Any], length: Int) -> Anchor? {
            guard let number = operation["p"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0, number.doubleValue <= Double(text.length), length >= 0 else { return nil }
            let offset = number.intValue
            guard length <= text.length - offset else { return nil }
            let range = NSRange(location: offset, length: length)
            guard Range(range, in: source) != nil else { return nil }
            return .init(file: file, source: source, version: value["version"] as? Int, offset: offset, length: length, documentID: documentID, localPathKnown: localPathKnown)
        }
        for row in ranges["comments"] as? [[String: Any]] ?? [] {
            guard let op = row["op"] as? [String: Any], let id = op["t"] as? String, let quote = op["c"] as? String,
                  let position = anchor(op, length: (quote as NSString).length), text.substring(with: NSRange(location: position.offset, length: position.length)) == quote else { continue }
            anchors[id] = position
        }
        let tracked = ranges["changes"] as? [[String: Any]] ?? []
        let counts = tracked.reduce(into: [String: Int]()) { result, row in if let id = row["id"] as? String { result[id, default: 0] += 1 } }
        for (index, row) in tracked.enumerated() {
            guard let id = row["id"] as? String, let op = row["op"] as? [String: Any] else { continue }
            let insertion = op["i"] as? String, deletion = op["d"] as? String
            guard (insertion == nil) != (deletion == nil), let content = insertion ?? deletion,
                  let position = anchor(op, length: insertion.map { ($0 as NSString).length } ?? 0) else { continue }
            if insertion != nil, text.substring(with: NSRange(location: position.offset, length: position.length)) != content { continue }
            let metadata = row["metadata"] as? [String: Any]
            changes.append(.init(id: documentID + ":" + id + ":" + String(index), documentID: documentID, changeID: id, insertion: insertion != nil, text: content, anchor: position, timestamp: metadata?["ts"] as? String ?? (metadata?["ts"] as? Double).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)) }, singleRange: counts[id] == 1))
        }
    }
}
