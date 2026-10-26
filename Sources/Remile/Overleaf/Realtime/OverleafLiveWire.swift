import Foundation
import CryptoKit

/// The legacy editor protocol is deliberately isolated from account and editor state.
enum OverleafLiveWire {
    static let frameLimit = 8_000_000
    enum Failure: LocalizedError {
        case protocolMismatch, disconnected, timeout, permission, authentication, changedTree, conflict, uncertain, handshake(Int)
        var errorDescription: String? {
            switch self {
            case .protocolMismatch: return "Overleaf returned an unsupported live response. Your local work is preserved."
            case .disconnected: return "Live connection stopped. Reconnect to reconcile your local work."
            case .timeout: return "Overleaf did not confirm the live operation. Reconnect before retrying."
            case .permission: return "This Overleaf session cannot edit the project."
            case .authentication: return "Reconnect your Overleaf account to use live sync."
            case .handshake(let status): return "Overleaf live handshake failed (HTTP \(status)). Your work stays on this Mac."
            case .changedTree: return "Project files changed. Stop live sync and review the project through Git."
            case .conflict: return "Overlapping edits need review. Both versions are preserved."
            case .uncertain: return "An earlier upload is unconfirmed. Review both versions before continuing."
            }
        }
    }
    enum JSON: Codable, Equatable, Sendable {
        case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSON].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSON].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
        subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        var string: String? { if case .string(let v) = self { return v }; return nil }
        var integer: Int? { if case .number(let v) = self { return Int(exactly: v) }; return nil }
        var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
        static func int(_ value: Int) -> JSON { .number(Double(value)) }
    }
    enum Packet: Equatable {
        case connected, heartbeat, closed
        case event(String, [JSON]), acknowledgement(Int, [JSON])
        case ignored
    }
    static func decode(_ text: String) throws -> Packet {
        guard text.utf8.count <= frameLimit else { throw Failure.protocolMismatch }
        let p = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard let kind = p.first else { throw Failure.protocolMismatch }
        switch kind {
        case "0": return .closed
        case "1": return .connected
        case "2": return .heartbeat
        case "5":
            guard p.count == 4, p[2].isEmpty,
                  let data = p[3].data(using: .utf8) else { throw Failure.protocolMismatch }
            let value = try JSONDecoder().decode(JSON.self, from: data)
            guard let name = value["name"].string, name.count <= 100, let args = value["args"].array, args.count <= 20 else { throw Failure.protocolMismatch }
            return .event(name, args)
        case "6":
            guard p.count == 4, p[2].isEmpty else { throw Failure.protocolMismatch }
            if let id = Int(p[3]), id > 0 { return .acknowledgement(id, []) }
            guard let plus = p[3].firstIndex(of: "+"),
                  let id = Int(p[3][..<plus]), id > 0,
                  let data = p[3][p[3].index(after: plus)...].data(using: .utf8),
                  let args = try JSONDecoder().decode(JSON.self, from: data).array else { throw Failure.protocolMismatch }
            return .acknowledgement(id, args)
        case "7": throw Failure.disconnected
        case "8": return .ignored
        default: throw Failure.protocolMismatch
        }
    }
    static func event(_ name: String, _ args: [JSON], id: Int? = nil) throws -> String {
        let data = try JSONEncoder().encode(JSON.object(["name": .string(name), "args": .array(args)]))
        guard data.count <= frameLimit, let body = String(data: data, encoding: .utf8), id.map({ $0 > 0 }) ?? true else { throw Failure.protocolMismatch }
        return (id.map { "5:\($0)+::" } ?? "5:::") + body
    }
    static func handshake(_ text: String) throws -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, parts[0].count <= 200,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let heartbeat = Double(parts[1]), heartbeat > 0, heartbeat <= 300,
              let close = Double(parts[2]), close > 0, close <= 600, parts[3].split(separator: ",").contains("websocket") else { throw Failure.protocolMismatch }
        return String(parts[0])
    }
    struct Document: Equatable, Sendable { let id: String; let path: String }
    static func documents(_ project: JSON, expectedID: String) throws -> [Document] {
        guard project["_id"].string == expectedID else { throw Failure.protocolMismatch }
        var result: [Document] = [], paths = Set<String>(), ids = Set<String>(), entries = 0
        func name(_ value: JSON) throws -> String {
            guard let s = value.string, !s.isEmpty, s != ".", s != "..", s != ".git", s.utf8.count <= 255,
                  !s.contains("/"), !s.contains("\\"), !s.unicodeScalars.contains(where: { $0.value < 32 }) else { throw Failure.protocolMismatch }
            return s
        }
        func walk(_ folders: [JSON], prefix: String, depth: Int) throws {
            guard depth < 32 else { throw Failure.protocolMismatch }
            for folder in folders {
                entries += 1; guard entries <= 10_000 else { throw Failure.protocolMismatch }
                let path: String
                if depth == 0 { path = "" }
                else { path = prefix + (try name(folder["name"])) + "/" }
                for kind in ["docs", "fileRefs"] {
                    for doc in folder[kind].array ?? [] {
                        entries += 1
                        let full = path + (try name(doc["name"]))
                        guard entries <= 10_000, full.utf8.count <= 4096, let id = doc["_id"].string,
                              id.count == 24, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), paths.insert(full).inserted, ids.insert(id).inserted else { throw Failure.protocolMismatch }
                        if kind == "docs" { result.append(Document(id: id, path: full)) }
                    }
                }
                try walk(folder["folders"].array ?? [], prefix: path, depth: depth + 1)
            }
        }
        let roots = project["rootFolder"].array ?? [project["rootFolder"]]
        guard roots.count == 1, roots[0] != .null else { throw Failure.protocolMismatch }
        try walk(roots, prefix: "", depth: 0)
        return result.sorted { $0.path < $1.path }
    }
    static func snapshot(_ args: [JSON]) throws -> OverleafLive.Snapshot {
        guard args.count >= 2, let lines = args[0].array, lines.count <= OverleafLive.textLimit,
              let version = args[1].integer else { throw Failure.protocolMismatch }
        let text = try lines.map { line -> String in
            guard let s = line.string else { throw Failure.protocolMismatch }
            let scalars = s.unicodeScalars
            if scalars.allSatisfy({ $0.value <= 255 }), let decoded = String(data: Data(scalars.map { UInt8($0.value) }), encoding: .utf8) { return decoded }
            return s
        }.joined(separator: "\n")
        let snapshot = OverleafLive.Snapshot(version: version, text: text); try snapshot.validate(); return snapshot
    }
    struct CatchUp: Sendable {
        let snapshot: OverleafLive.Snapshot
        let operations: [JSON]
        /// Only a complete, contiguous history can establish that a prior source was applied.
        func contains(_ submission: OverleafLive.Submission, base: OverleafLive.Snapshot) throws -> Bool {
            guard let sources = submission.sources, snapshot.version >= base.version,
                  snapshot.version - base.version == operations.count, operations.count <= 1_000 else { throw Failure.uncertain }
            var text = base.text, matched = false
            for (index, operation) in operations.enumerated() {
                guard operation["v"].integer == base.version + index, let components = operation["op"].array else { throw Failure.uncertain }
                text = try OverleafLiveText.applying(components, to: text)
                if let source = operation["meta"]["source"].string, sources.contains(source) { matched = true }
            }
            guard text == snapshot.text else { throw Failure.uncertain }
            return matched
        }
    }
    static func update(_ operation: OverleafLive.Submission) -> JSON {
        let edit = operation.edit
        var ops: [JSON] = []
        if !edit.deleted.isEmpty { ops.append(.object(["p": .int(edit.offset), "d": .string(edit.deleted)])) }
        if !edit.inserted.isEmpty { ops.append(.object(["p": .int(edit.offset), "i": .string(edit.inserted)])) }
        if operation.rejecting == true {
            ops = ops.map { value in
                guard case .object(var fields) = value else { return value }
                fields["u"] = .bool(true)
                return .object(fields)
            }
        }
        let digest = Insecure.SHA1.hash(data: Data(("blob \(operation.after.utf16.count)\0" + operation.after).utf8)).map { String(format: "%02x", $0) }.joined()
        var value: [String: JSON] = ["doc": .string(operation.key.document), "op": .array(ops), "v": .int(operation.baseVersion), "lastV": .int(operation.baseVersion), "hash": .string(digest)]
        if let sources = operation.sources { value["dupIfSource"] = .array(sources.map(JSON.string)) }
        return .object(value)
    }
}
