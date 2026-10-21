import Foundation

// Bounded classic-xref parsing for PDFKit output and unencrypted incremental revisions.
// Cross-reference streams and hybrid files fail closed.
enum PDFReplyWriter {
    struct Reference: Hashable { let object: Int; let generation: Int }
    struct Link { let child: Reference; let parent: Reference }
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "The PDF comment references could not be preserved. No changes were saved." }
    }
    struct Entry { let name: String; let range: Range<Int>; let value: Value }
    indirect enum Kind {
        case atom(String), name(String), reference(Reference), array([Value]), dictionary([Entry])
    }
    struct Value {
        let range: Range<Int>
        let kind: Kind
        var entries: [Entry] { if case .dictionary(let entries) = kind { return entries }; return [] }
        subscript(_ key: String) -> Value? { entries.first { $0.name == key }?.value }
        var reference: Reference? { if case .reference(let ref) = kind { return ref }; return nil }
        var array: [Value]? { if case .array(let values) = kind { return values }; return nil }
        var name: String? { if case .name(let name) = kind { return name }; return nil }
        var integer: Int? { if case .atom(let text) = kind { return Int(text) }; return nil }
        var number: Double? { if case .atom(let text) = kind { return Double(text) }; return nil }
    }

    struct Parser {
        let bytes: Data
        var index: Int
        init(bytes: Data, index: Int) { self.bytes = bytes; self.index = index }
        init(bytes: [UInt8], index: Int) { self.bytes = Data(bytes); self.index = index }
        mutating func whitespace() {
            while index < bytes.count {
                if [0,9,10,12,13,32].contains(bytes[index]) { index += 1 }
                else if bytes[index] == 37 { while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 { index += 1 } }
                else { return }
            }
        }
        mutating func token() throws -> String {
            whitespace()
            let start = index
            while index < bytes.count && ![0,9,10,12,13,32,40,41,60,62,91,93,123,125,47,37].contains(bytes[index]) { index += 1 }
            guard index > start else { throw Failure.unsupported }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        mutating func value(depth: Int = 0) throws -> Value {
            guard depth < 64 else { throw Failure.unsupported }
            whitespace()
            let start = index
            guard index < bytes.count else { throw Failure.unsupported }
            let kind: Kind
            if bytes[index] == 60 && index + 1 < bytes.count && bytes[index + 1] == 60 {
                index += 2
                var entries: [Entry] = []
                while true {
                    whitespace()
                    guard index + 1 < bytes.count else { throw Failure.unsupported }
                    if bytes[index] == 62 && bytes[index + 1] == 62 { index += 2; break }
                    let keyStart = index
                    let key = try value(depth: depth + 1)
                    guard let name = key.name, !entries.contains(where: { $0.name == name }) else { throw Failure.unsupported }
                    let child = try value(depth: depth + 1)
                    entries.append(Entry(name: name, range: keyStart..<index, value: child))
                }
                kind = .dictionary(entries)
            } else if bytes[index] == 91 {
                index += 1
                var values: [Value] = []
                while true {
                    whitespace()
                    guard index < bytes.count else { throw Failure.unsupported }
                    if bytes[index] == 93 { index += 1; break }
                    values.append(try value(depth: depth + 1))
                }
                kind = .array(values)
            } else if bytes[index] == 47 {
                index += 1
                let nameStart = index
                while index < bytes.count && ![0,9,10,12,13,32,40,41,60,62,91,93,123,125,47,37].contains(bytes[index]) { index += 1 }
                // PDFKit uses escaped names for destinations as well as ordinary dictionary keys.
                var decoded: [UInt8] = [], position = nameStart
                func hex(_ value: UInt8) -> UInt8? {
                    if value >= 48 && value <= 57 { return value - 48 }
                    if value >= 65 && value <= 70 { return value - 55 }
                    if value >= 97 && value <= 102 { return value - 87 }
                    return nil
                }
                while position < index {
                    if bytes[position] == 35 {
                        guard position + 2 < index, let high = hex(bytes[position + 1]), let low = hex(bytes[position + 2]), high * 16 + low != 0 else { throw Failure.unsupported }
                        decoded.append(high * 16 + low); position += 3
                    } else { decoded.append(bytes[position]); position += 1 }
                }
                guard let name = String(bytes: decoded, encoding: .utf8) else { throw Failure.unsupported }
                kind = .name(name)
            } else if bytes[index] == 40 {
                index += 1
                var nesting = 1
                while index < bytes.count && nesting > 0 {
                    let byte = bytes[index]; index += 1
                    if byte == 92 { guard index < bytes.count else { throw Failure.unsupported }; index += 1 }
                    else if byte == 40 { nesting += 1 }
                    else if byte == 41 { nesting -= 1 }
                }
                guard nesting == 0 else { throw Failure.unsupported }
                kind = .atom("string")
            } else if bytes[index] == 60 {
                index += 1
                while index < bytes.count && bytes[index] != 62 { index += 1 }
                guard index < bytes.count else { throw Failure.unsupported }
                index += 1
                kind = .atom("hex")
            } else {
                let first = try token()
                let end = index
                if let object = Int(first), object > 0 {
                    var lookahead = self
                    if let next = try? lookahead.token(), let generation = Int(next), generation >= 0,
                       (try? lookahead.token()) == "R" {
                        self = lookahead
                        return Value(range: start..<index, kind: .reference(Reference(object: object, generation: generation)))
                    }
                }
                index = end
                kind = .atom(first)
            }
            return Value(range: start..<index, kind: kind)
        }
    }

    struct File {
        let data: Data
        let bytes: Data
        let xref: Int
        let trailer: Value
        let offsets: [Reference: Int]
        init(_ data: Data) throws {
            guard data.startIndex == 0 else { throw Failure.unsupported }
            self.data = data
            // Data shares immutable storage, avoiding a full [UInt8] copy during every save.
            bytes = data
            guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else { throw Failure.unsupported }
            var tail = Parser(bytes: bytes, index: marker.upperBound)
            guard let offset = Int(try tail.token()), offset >= 0, offset < bytes.count else { throw Failure.unsupported }
            xref = offset
            var result: [Reference: Int] = [:], seenObjects = Set<Int>(), revisions = Set<Int>()
            var current: Int? = offset, latest: Value?
            while let revision = current {
                guard revisions.count < 128, revisions.insert(revision).inserted,
                      revision >= 0, revision < bytes.count else { throw Failure.unsupported }
                var parser = Parser(bytes: bytes, index: revision)
                guard try parser.token() == "xref" else { throw Failure.unsupported }
                var local = Set<Int>()
                while true {
                    let token = try parser.token()
                    if token == "trailer" { break }
                    guard let start = Int(token), start >= 0, start <= bytes.count,
                          let count = Int(try parser.token()), count >= 0, count <= bytes.count / 10,
                          start <= Int.max - count else { throw Failure.unsupported }
                    for number in start..<(start + count) {
                        guard local.insert(number).inserted, let position = Int(try parser.token()),
                              let generation = Int(try parser.token()), generation >= 0, generation <= 65535 else { throw Failure.unsupported }
                        let status = try parser.token()
                        guard status == "n" || status == "f" else { throw Failure.unsupported }
                        // A free entry in a newer revision also shadows an older live object.
                        let newest = seenObjects.insert(number).inserted
                        if status == "n" {
                            guard number > 0, position > 0, position < revision else { throw Failure.unsupported }
                            if newest { result[Reference(object: number, generation: generation)] = position }
                        }
                    }
                }
                let entry = try parser.value()
                guard case .dictionary = entry.kind, entry["Encrypt"] == nil, entry["XRefStm"] == nil else { throw Failure.unsupported }
                if latest == nil { latest = entry }
                if let prev = entry["Prev"] {
                    guard let previous = prev.integer, previous >= 0, previous < revision else { throw Failure.unsupported }
                    current = previous
                } else { current = nil }
            }
            guard let latest, latest["Root"]?.reference != nil, let size = latest["Size"]?.integer,
                  size > 0, size <= bytes.count, result.keys.allSatisfy({ $0.object < size }) else { throw Failure.unsupported }
            trailer = latest
            offsets = result
        }
        func object(_ ref: Reference) throws -> Value {
            guard let offset = offsets[ref] else { throw Failure.unsupported }
            var parser = Parser(bytes: bytes, index: offset)
            guard try parser.token() == String(ref.object), try parser.token() == String(ref.generation), try parser.token() == "obj" else { throw Failure.unsupported }
            return try parser.value()
        }
        func resolved(_ value: Value) throws -> Value {
            if let ref = value.reference { return try object(ref) }
            return value
        }
        func pages() throws -> [Reference] {
            let catalog = try object(trailer["Root"]!.reference!)
            guard let root = catalog["Pages"]?.reference else { throw Failure.unsupported }
            var visited = Set<Reference>()
            func walk(_ ref: Reference, depth: Int) throws -> [Reference] {
                guard depth < 64, visited.insert(ref).inserted else { throw Failure.unsupported }
                let node = try object(ref)
                if node["Type"]?.name == "Page" { return [ref] }
                guard node["Type"]?.name == "Pages", let children = node["Kids"]?.array else { throw Failure.unsupported }
                return try children.flatMap { child in
                    guard let ref = child.reference else { throw Failure.unsupported }
                    return try walk(ref, depth: depth + 1)
                }
            }
            return try walk(root, depth: 0)
        }
        func annotations(on page: Reference) throws -> [Reference] {
            guard let annots = try object(page)["Annots"] else { return [] }
            guard let values = try resolved(annots).array else { throw Failure.unsupported }
            return try values.compactMap { value in
                guard let ref = value.reference else { throw Failure.unsupported }
                return try object(ref)["Subtype"]?.name == "Popup" ? nil : ref
            }
        }
    }

    static func write(_ file: File, links: [Link], names: [Reference: String]) throws -> Data {
        var patches: [Reference: [String: String]] = [:]
        for (ref, name) in names {
            guard !name.isEmpty else { throw Failure.unsupported }
            let hex = name.utf16.map { String(format: "%04X", $0) }.joined()
            patches[ref] = ["NM": "<FEFF\(hex)>"]
        }
        for link in links {
            guard link.child != link.parent, file.offsets[link.parent] != nil else { throw Failure.unsupported }
            patches[link.child, default: [:]]["IRT"] = "\(link.parent.object) \(link.parent.generation) R"
            patches[link.child, default: [:]]["RT"] = "/R"
        }
        return try replacingDictionaries(file, patches: patches)
    }

    /// A complete classic cross-reference table makes the next structural edit independently readable.
    static func replacingDictionaries(_ file: File, patches: [Reference: [String: String]], objects: [Reference: Data] = [:], incremental: Bool = false) throws -> Data {
        if patches.isEmpty && objects.isEmpty { return file.data }
        var output = file.data
        output.append(Data("\n".utf8))
        var offsets: [Reference: Int] = incremental ? [:] : file.offsets
        for ref in patches.keys.sorted(by: { $0.object < $1.object }) {
            let value = try file.object(ref)
            guard case .dictionary = value.kind, let additions = patches[ref] else { throw Failure.unsupported }
            offsets[ref] = output.count
            output.append(Data("\(ref.object) \(ref.generation) obj\n<< ".utf8))
            for entry in value.entries where additions[entry.name] == nil {
                output.append(contentsOf: file.bytes[entry.range]); output.append(32)
            }
            for key in additions.keys.sorted() { output.append(Data("/\(key) \(additions[key]!) ".utf8)) }
            output.append(Data(">>\nendobj\n".utf8))
        }
        for ref in objects.keys.sorted(by: { $0.object < $1.object }) {
            guard patches[ref] == nil, let bytes = objects[ref] else { throw Failure.unsupported }
            offsets[ref] = output.count
            output.append(Data("\(ref.object) \(ref.generation) obj\n".utf8)); output.append(bytes)
            output.append(Data("\nendobj\n".utf8))
        }
        guard let originalSize = file.trailer["Size"]?.integer, originalSize > 0, originalSize <= file.bytes.count else { throw Failure.unsupported }
        let size = max(originalSize, (offsets.keys.map(\.object).max() ?? 0) + 1)
        guard size <= file.bytes.count + 20000 else { throw Failure.unsupported }
        var indexed: [Int: (Reference, Int)] = [:]
        for (ref, offset) in offsets {
            guard ref.object < size, indexed[ref.object] == nil, offset < 10_000_000_000, ref.generation < 100_000 else { throw Failure.unsupported }
            indexed[ref.object] = (ref, offset)
        }
        let xref = output.count
        output.append(Data("xref\n".utf8))
        if incremental {
            // Only changed/new objects are in this revision. The original xref remains authoritative.
            for number in indexed.keys.sorted() {
                let (ref, offset) = indexed[number]!
                output.append(Data("\(number) 1\n".utf8))
                output.append(Data(String(format: "%010lld %05d n \n", offset, ref.generation).utf8))
            }
        } else {
            output.append(Data("0 \(size)\n0000000000 65535 f \n".utf8))
            for number in 1..<size {
                if let (ref, offset) = indexed[number] { output.append(Data(String(format: "%010lld %05d n \n", offset, ref.generation).utf8)) }
                else { output.append(Data("0000000000 00000 f \n".utf8)) }
            }
        }
        output.append(Data("trailer\n<< ".utf8))
        for entry in file.trailer.entries where entry.name != "Prev" && entry.name != "XRefStm" && entry.name != "Size" {
            output.append(contentsOf: file.bytes[entry.range]); output.append(32)
        }
        if incremental { output.append(Data("/Prev \(file.xref) ".utf8)) }
        output.append(Data("/Size \(size) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }
}
