import Foundation

extension OverleafReviewSnapshot {
    var reviewSources: [String: String] {
        var result: [String: String] = [:]
        for anchor in Array(anchors.values) + changes.map(\.anchor) where anchor.localPathKnown { result[anchor.file] = anchor.source }
        return result
    }
    func export(json: Bool) throws -> Data {
        func context(_ anchor: Anchor) -> (line: Int, text: String) {
            let source = anchor.source as NSString
            let start = max(0, anchor.offset - 350), end = min(source.length, anchor.offset + min(anchor.length, 1200) + 350)
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            return (source.substring(to: range.location).filter { $0 == "\n" }.count + 1, source.substring(with: range))
        }
        func source(_ anchor: Anchor) -> [String: Any] {
            let excerpt = context(anchor)
            var result: [String: Any] = ["file": anchor.file, "pathResolved": anchor.localPathKnown, "line": anchor.line + 1, "offsetUTF16": anchor.offset, "lengthUTF16": anchor.length, "sourceSHA256": SourceDigest.sha256(anchor.source), "quote": (anchor.source as NSString).substring(with: NSRange(location: anchor.offset, length: anchor.length)), "context": ["startLine": excerpt.line, "text": excerpt.text]]
            if let documentID = anchor.documentID { result["documentID"] = documentID }
            if let version = anchor.version { result["version"] = version }
            return result
        }
        let hashes = reviewSources.mapValues(SourceDigest.sha256)
        if json {
            var result = try JSONSerialization.jsonObject(with: archive.data(json: true)) as? [String: Any] ?? [:]
            result["schemaVersion"] = 3
            result["observedAt"] = ISO8601DateFormatter().string(from: observedAt)
            result["projectReference"] = "overleaf:" + archive.projectID
            result["sourceHashes"] = hashes
            if let main { result["main"] = main }
            result["sourceLocations"] = anchors.mapValues(source)
            result["changes"] = changes.map { change -> [String: Any] in
                var record: [String: Any] = ["id": change.changeID, "documentID": change.documentID, "singleRange": change.singleRange, "type": change.insertion ? "insertion" : "deletion", "text": change.text, "source": source(change.anchor)]
                if let timestamp = change.timestamp { record["timestamp"] = timestamp }
                if let author = change.author { record["author"] = author }
                return record
            }
            if let warning { result["warning"] = warning }
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        func literal(_ value: String) -> String {
            var result = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            for token in ["\\", "`", "*", "_", "[", "]", "#"] { result = result.replacingOccurrences(of: token, with: "\\" + token) }
            return result
        }
        func heading(_ anchor: Anchor?) -> String { anchor.map { literal($0.file) + " · Line \($0.line + 1)" } ?? "Source location unavailable" }
        func quote(_ text: String) -> String { text.components(separatedBy: "\n").map { "> " + literal($0) }.joined(separator: "\n") }
        func sourceLines(_ anchor: Anchor?) -> [String] {
            guard let anchor else { return [] }
            let value = context(anchor)
            var result = ["Source SHA-256: `\(SourceDigest.sha256(anchor.source))`", ""]
            if let document = anchor.documentID { result += ["Document: `" + literal(document) + "`", ""] }
            if !anchor.localPathKnown { result += ["The local source path is unresolved.", ""] }
            let selected = (anchor.source as NSString).substring(with: NSRange(location: anchor.offset, length: anchor.length))
            if !selected.isEmpty { result += ["Anchored text:", "", quote(selected), ""] }
            // Indented code preserves literal TeX and cannot be closed by a fence in the source.
            result += ["Source excerpt near line \(value.line):", ""] + value.text.components(separatedBy: "\n").map { "    " + $0 } + [""]
            return result
        }
        let sampleFile = main ?? reviewSources.keys.sorted().first ?? "main.tex"
        let quotedFile = "'" + sampleFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var lines = ["# Review — " + literal(archive.project), "", "Project: `overleaf:\(archive.projectID)`", "Observed: " + ISO8601DateFormatter().string(from: observedAt), ""]
        if let main { lines += ["Main source: `" + literal(main) + "`", ""] }
        lines += ["Line numbers and hashes refer to the review snapshot. If source hashes differ, locate the anchored text before editing.", "", "Agent commands:", "", "    remile overleaf review --id overleaf:\(archive.projectID) --format json", "    remile overleaf read --id overleaf:\(archive.projectID) --file " + quotedFile, ""]
        if let warning { lines += [literal(warning), ""] }
        lines += ["## Comments", ""]
        if archive.threads.isEmpty { lines += ["No comments.", ""] }
        for thread in archive.threads {
            lines += ["### " + heading(anchors[thread.id]), "", "Thread: `" + literal(thread.id) + "` · " + (thread.resolved ? "Resolved" : "Open"), ""]
            for message in thread.messages {
                lines += [literal(message.author) + (message.timestamp.map { " · " + literal($0) } ?? ""), "Message: `" + literal(message.id) + "`", "", quote(message.text), ""]
            }
            lines += sourceLines(anchors[thread.id])
        }
        lines += ["## Changes", ""]
        if changes.isEmpty { lines += [warning == nil ? "No tracked changes." : "Changes unavailable.", ""] }
        for change in changes {
            lines += ["### " + (change.insertion ? "Added" : "Deleted") + " · " + heading(change.anchor), "", "Change: `" + literal(change.changeID) + "`", ""]
            if let timestamp = change.timestamp { lines += [literal(timestamp), ""] }
            lines += [quote(change.text), ""] + sourceLines(change.anchor)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    func response(format: String, output: String?) throws -> [String: Any] {
        guard ["json", "markdown"].contains(format) else { throw OverleafGit.Failure("Use json or markdown for review notes.") }
        let bytes = try export(json: format == "json")
        if let output {
            let url = URL(fileURLWithPath: output)
            guard output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output), url.pathExtension.lowercased() == (format == "json" ? "json" : "md") else { throw CocoaError(.fileWriteFileExists) }
            try bytes.write(to: url, options: .atomic)
            return ["ok": true, "output": output, "comments": archive.threads.count, "changes": changes.count, "complete": warning == nil]
        }
        if format == "markdown" { return ["ok": true, "projectReference": "overleaf:" + archive.projectID, "markdown": String(decoding: bytes, as: UTF8.self), "complete": warning == nil] }
        var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        result["ok"] = true; result["complete"] = warning == nil
        return result
    }
}
