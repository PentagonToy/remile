import Foundation

struct OverleafThreadArchive: Codable {
    let schemaVersion: Int
    let project: String
    let projectID: String
    let threads: [Thread]
    func response(format: PDFCommentExport.Format, output: String?) throws -> [String: Any] {
        let bytes = try data(json: format == .json)
        if let output {
            guard output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output), URL(fileURLWithPath: output).pathExtension.lowercased() == (format == .json ? "json" : "md") else { throw CocoaError(.fileWriteFileExists) }
            try bytes.write(to: URL(fileURLWithPath: output), options: .atomic)
            return ["ok": true, "output": output, "count": threads.count, "format": format.rawValue]
        }
        if format == .markdown { return ["ok": true, "project": project, "markdown": String(decoding: bytes, as: UTF8.self)] }
        var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]; result["ok"] = true; return result
    }
    struct Thread: Codable, Identifiable {
        let id: String
        let resolved: Bool
        let resolvedAt: String?
        let messages: [Message]
    }
    struct Message: Codable, Identifiable {
        let id: String
        let author: String
        let text: String
        let timestamp: String?
    }
    static func parse(_ data: Data, project: OverleafConnection) throws -> Self {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { throw OverleafGit.Failure("The server returned an unfamiliar comment format.") }
        let threads = try raw.keys.sorted().map { id -> Thread in
            guard let thread = raw[id], let messages = thread["messages"] as? [[String: Any]] else { throw OverleafGit.Failure("The server returned an unfamiliar comment thread.") }
            let parsed = try messages.map { value -> Message in
                guard let id = value["id"] as? String, let text = value["content"] as? String else { throw OverleafGit.Failure("The server returned an unfamiliar comment message.") }
                let user = value["user"] as? [String: Any]
                let timestamp = (value["timestamp"] as? String) ?? (value["timestamp"] as? Double).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)) }
                let fullName = [user?["first_name"] as? String, user?["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                return Message(id: id, author: user?["name"] as? String ?? (fullName.isEmpty ? nil : fullName) ?? "Contributor", text: text, timestamp: timestamp)
            }
            return Thread(id: id, resolved: thread["resolved"] as? Bool ?? false, resolvedAt: thread["resolved_at"] as? String, messages: parsed)
        }
        return Self(schemaVersion: 1, project: project.name, projectID: project.projectID, threads: threads)
    }
    func data(json: Bool) throws -> Data {
        if json { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
        func safe(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["# Comments — " + safe(project), "", "Project: " + projectID, ""]
        for thread in threads {
            lines += ["## Thread `\(thread.id)`", "", thread.resolved ? "Resolved" : "Open", ""]
            if let resolvedAt = thread.resolvedAt { lines += ["Resolved: " + safe(resolvedAt), ""] }
            for (index, message) in thread.messages.enumerated() {
                lines += ["### " + (index == 0 ? "" : "Reply · ") + safe(message.author), "", "Message: `\(message.id)`"]
                if let date = message.timestamp { lines += ["Date: " + safe(date)] }
                lines += [""] + message.text.components(separatedBy: .newlines).map { "> " + safe($0) } + [""]
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
