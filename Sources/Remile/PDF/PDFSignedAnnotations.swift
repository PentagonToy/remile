import PDFKit
import CryptoKit
import Security

/// Retain the signed revision verbatim. Only page Annots and newly allocated annotation objects may change.
/// This preserves signed bytes, not certificate trust, expiry or revocation status.
final class PDFSignedAnnotations {
    typealias Ref = PDFReplyWriter.Reference
    typealias File = PDFReplyWriter.File
    typealias Value = PDFReplyWriter.Value
    enum Failure: LocalizedError {
        case unsupported, forbidden, changed, damaged
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This PDF's signature cannot be preserved by the supported annotation writer. The original was not changed."
            case .forbidden: return "The signature does not permit annotations. The original was not changed."
            case .damaged: return "An existing signature failed its integrity check. Saving requires confirmation."
            case .changed: return "Only annotation changes can be saved while preserving this signature. The original was not changed."
            }
        }
    }
    static let markupTypes: Set<String> = ["Text", "FreeText", "Highlight", "Underline", "Squiggly", "StrikeOut", "Ink", "Square", "Circle", "Line", "Polygon", "PolyLine", "Stamp"]
    private let original: Data
    private let pages: [PDFPage]
    private let geometry: [(Int, CGRect, CGRect)]
    private let forms: String?
    private let existing: [ObjectIdentifier: Ref]
    private let fingerprints: [ObjectIdentifier: String]

    struct Source {
        let data: Data
        let pages: [PDFPage]
        let annotations: [[PDFAnnotation]]
        let geometry: [(Int, CGRect, CGRect)]
        init(document: PDFDocument, data: Data) {
            self.data = data
            pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
            annotations = pages.map { $0.annotations.filter { $0.type != "Popup" } }
            geometry = pages.map { ($0.rotation, $0.bounds(for: .mediaBox), $0.bounds(for: .cropBox)) }
        }
    }
    init(source: Source) throws {
        let data = source.data
        guard data.count <= 256_000_000, let document = PDFDocument(data: data) else { throw Failure.unsupported }
        let file = try File(data)
        try Self.permissions(file)
        let pageRefs = try file.pages()
        guard pageRefs.count == document.pageCount else { throw Failure.unsupported }
        original = data
        pages = source.pages
        guard pages.count == document.pageCount else { throw Failure.unsupported }
        geometry = source.geometry
        forms = try PDFFormPreservation.snapshot(document)
        guard let bytes = document.dataRepresentation() else { throw Failure.unsupported }
        let rewritten = try File(bytes), rewrittenPages = try rewritten.pages()
        guard rewrittenPages.count == pages.count else { throw Failure.unsupported }
        var identities: [ObjectIdentifier: Ref] = [:], snapshots: [ObjectIdentifier: String] = [:]
        for index in pages.indices {
            let annotations = source.annotations[index]
            let refs = try file.annotations(on: pageRefs[index]), tempRefs = try rewritten.annotations(on: rewrittenPages[index])
            guard refs.count == annotations.count, tempRefs.count == refs.count else { throw Failure.unsupported }
            for (position, annotation) in annotations.enumerated() {
                guard try file.object(refs[position])["Subtype"]?.name == annotation.type else { throw Failure.unsupported }
                let id = ObjectIdentifier(annotation)
                guard identities[id] == nil else { throw Failure.unsupported }
                identities[id] = refs[position]
                snapshots[id] = try Self.fingerprint(tempRefs[position], in: rewritten)
            }
        }
        existing = identities; fingerprints = snapshots
    }

    /// Signed approval documents may receive annotations. Certification additionally requires DocMDP P=3.
    private static func permissions(_ file: File) throws {
        let catalog = try file.object(file.trailer["Root"]!.reference!)
        guard let formValue = catalog["AcroForm"], let fieldsValue = try file.resolved(formValue)["Fields"],
              let fields = try file.resolved(fieldsValue).array else { throw Failure.unsupported }
        var verificationBytes = 0
        var count = 0, signatures = [Value](), visited = Set<Ref>()
        func visit(_ value: Value, type: String? = nil, depth: Int = 0) throws {
            count += 1
            guard count <= 10_000, depth < 32 else { throw Failure.unsupported }
            if let ref = value.reference { guard visited.insert(ref).inserted else { throw Failure.unsupported } }
            let field = try file.resolved(value), inherited = field["FT"]?.name ?? type
            if inherited == "Sig", let value = field["V"] {
                let signature = try file.resolved(value)
                guard ["adbe.pkcs7.detached", "ETSI.CAdES.detached"].contains(signature["SubFilter"]?.name ?? ""),
                      let ranges = signature["ByteRange"]?.array, ranges.count == 4,
                      let zero = ranges[0].integer, zero == 0, let first = ranges[1].integer,
                      let second = ranges[2].integer, let length = ranges[3].integer,
                      let contents = signature["Contents"], case .atom("hex") = contents.kind,
                      first == contents.range.lowerBound, second == contents.range.upperBound,
                      length > 0, second < file.bytes.count, length <= file.bytes.count - second else { throw Failure.unsupported }
                guard first <= 64_000_000, length <= 64_000_000 - first, verificationBytes <= 128_000_000 - first - length else { throw Failure.unsupported }
                verificationBytes += first + length
                try verifyCMS(file: file, contents: contents, first: first, second: second, length: length)
                signatures.append(signature)
            }
            if let children = field["Kids"] {
                guard let list = try file.resolved(children).array else { throw Failure.unsupported }
                for child in list { try visit(child, type: inherited, depth: depth + 1) }
            }
        }
        for field in fields { try visit(field) }
        guard !signatures.isEmpty else { throw Failure.unsupported }
        var certification: Value?
        if let entry = catalog["Perms"] {
            let permissions = try file.resolved(entry)
            guard permissions.entries.count == 1, let docMDP = permissions["DocMDP"] else { throw Failure.unsupported }
            certification = try file.resolved(docMDP)
            guard signatures.contains(where: { $0.range == certification!.range }) else { throw Failure.unsupported }
        }
        var certifications = 0
        for signature in signatures {
            guard let entry = signature["Reference"] else {
                if certification?.range == signature.range { throw Failure.unsupported }
                continue
            }
            guard let transforms = try file.resolved(entry).array else { throw Failure.unsupported }
            for transform in transforms {
                let reference = try file.resolved(transform)
                switch reference["TransformMethod"]?.name {
                case "DocMDP":
                    certifications += 1
                    guard certification?.range == signature.range, let value = reference["TransformParams"] else { throw Failure.unsupported }
                    let params = try file.resolved(value)
                    guard params["P"]?.integer == 3 else { throw Failure.forbidden }
                case "FieldMDP":
                    // No field or widget is rewritten. Unknown transforms are never treated as permission.
                    guard let value = reference["TransformParams"], ["All", "Include", "Exclude"].contains(try file.resolved(value)["Action"]?.name ?? "") else { throw Failure.unsupported }
                default: throw Failure.unsupported
                }
            }
        }
        guard certification == nil ? certifications == 0 : certifications == 1 else { throw Failure.unsupported }
    }

    /// Offline CMS integrity verification. No certificate trust evaluation, keychain changes or network calls.
    private static func verifyCMS(file: File, contents: Value, first: Int, second: Int, length: Int) throws {
        guard contents.range.count <= 1_000_000 else { throw Failure.unsupported }
        var cms = Data(), high: UInt8?
        for byte in file.bytes[(contents.range.lowerBound + 1)..<(contents.range.upperBound - 1)] {
            if [0, 9, 10, 12, 13, 32].contains(byte) { continue }
            let nibble: UInt8
            switch byte {
            case 48...57: nibble = byte - 48
            case 65...70: nibble = byte - 55
            case 97...102: nibble = byte - 87
            default: throw Failure.damaged
            }
            if let value = high { cms.append(value * 16 + nibble); high = nil } else { high = nibble }
        }
        guard high == nil, cms.count >= 2, cms[0] == 0x30 else { throw Failure.damaged }
        var header = 2, body = Int(cms[1])
        if body & 0x80 != 0 {
            let octets = body & 0x7f
            guard octets > 0, octets <= 4, cms.count >= 2 + octets else { throw Failure.damaged }
            body = 0
            for index in 2..<(2 + octets) { body = body * 256 + Int(cms[index]) }
            header += octets
        }
        guard body <= cms.count - header, cms[(header + body)...].allSatisfy({ $0 == 0 }) else { throw Failure.damaged }
        cms = Data(cms.prefix(header + body))
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { throw Failure.unsupported }
        let update = cms.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard update == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { throw Failure.damaged }
        var detached = Data(capacity: first + length)
        detached.append(file.data.prefix(first)); detached.append(file.data[second..<(second + length)])
        guard CMSDecoderSetDetachedContent(decoder, detached as CFData) == errSecSuccess else { throw Failure.damaged }
        var signers = 0
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers > 0, signers <= 16 else { throw Failure.damaged }
        let policy = SecPolicyCreateBasicX509()
        for index in 0..<signers {
            var status = CMSSignerStatus.unsigned, trust: SecTrust?
            guard CMSDecoderCopySignerStatus(decoder, index, policy, false, &status, &trust, nil) == errSecSuccess,
                  status == .valid else { throw Failure.damaged }
        }
    }

    func serialize(_ document: PDFDocument, rewritten: File, refs: [ObjectIdentifier: Ref], names: [Ref: String], links: [PDFReplyWriter.Link]) throws -> Data {
        guard document.pageCount == pages.count, try PDFFormPreservation.snapshot(document) == forms else { throw Failure.changed }
        let file = try File(original), pageRefs = try file.pages()
        var live = Set<ObjectIdentifier>(), mapping = [Ref: Ref](), objects = [Ref: Data](), patches = [Ref: [String: String]]()
        var next = file.trailer["Size"]!.integer!
        for (index, page) in pages.enumerated() {
            let (rotation, media, crop) = geometry[index]
            guard document.page(at: index) === page, page.rotation == rotation,
                  page.bounds(for: .mediaBox) == media, page.bounds(for: .cropBox) == crop else { throw Failure.changed }
            for annotation in page.annotations where annotation.type != "Popup" {
                let id = ObjectIdentifier(annotation)
                guard live.insert(id).inserted, let tempRef = refs[id] else { throw Failure.unsupported }
                if let ref = existing[id] {
                    guard try Self.fingerprint(tempRef, in: rewritten) == fingerprints[id] else { throw Failure.changed }
                    mapping[tempRef] = ref
                } else {
                    guard Self.markupTypes.contains(annotation.type ?? ""), next < Int.max - 20_000 else { throw Failure.unsupported }
                    mapping[tempRef] = Ref(object: next, generation: 0); next += 1
                }
            }
        }
        let retained = Set(existing.filter { live.contains($0.key) }.map(\.value))
        for (id, ref) in existing where !live.contains(id) {
            guard Self.markupTypes.contains(try file.object(ref)["Subtype"]?.name ?? "") else { throw Failure.changed }
        }
        var copying = Set<Ref>(), remaining = 200_000
        func render(_ value: Value, depth: Int = 0) throws -> Data {
            remaining -= 1; guard remaining > 0, depth < 64 else { throw Failure.unsupported }
            switch value.kind {
            case .reference(let ref):
                let destination: Ref
                if let known = mapping[ref] { destination = known }
                else { destination = Ref(object: next, generation: 0); next += 1; mapping[ref] = destination }
                if !existing.values.contains(destination), objects[destination] == nil, !copying.contains(ref), !refs.values.contains(ref) { try copy(ref, to: destination, page: nil, depth: depth + 1) }
                return Data("\(destination.object) \(destination.generation) R".utf8)
            case .array(let entries):
                var result = Data("[ ".utf8)
                for entry in entries { result.append(try render(entry, depth: depth + 1)); result.append(32) }
                result.append(93); return result
            case .dictionary(let entries):
                var result = Data("<< ".utf8)
                for entry in entries {
                    // Preserve escaped key spelling exactly.
                    result.append(contentsOf: rewritten.bytes[entry.range.lowerBound..<entry.value.range.lowerBound])
                    result.append(try render(entry.value, depth: depth + 1)); result.append(32)
                }
                result.append(Data(">>".utf8)); return result
            default: return Data(rewritten.bytes[value.range])
            }
        }
        func copy(_ ref: Ref, to destination: Ref, page: Ref?, depth: Int) throws {
            guard depth < 64, objects.count < 20_000, copying.insert(ref).inserted else { throw Failure.unsupported }
            defer { copying.remove(ref) }
            let value = try rewritten.object(ref)
            if let type = value["Type"]?.name, ["Page", "Pages", "Catalog", "Sig"].contains(type) { throw Failure.unsupported }
            var body: Data
            if let page {
                guard case .dictionary = value.kind,
                      Self.markupTypes.contains(value["Subtype"]?.name ?? ""),
                      value["A"] == nil, value["AA"] == nil, value["FS"] == nil else { throw Failure.unsupported }
                body = Data("<< ".utf8)
                for entry in value.entries where !["P", "Popup", "NM", "IRT", "RT"].contains(entry.name) {
                    body.append(contentsOf: rewritten.bytes[entry.range.lowerBound..<entry.value.range.lowerBound])
                    body.append(try render(entry.value, depth: depth + 1)); body.append(32)
                }
                if let name = names[ref] {
                    body.append(Data(("/NM <FEFF" + name.utf16.map { String(format: "%04X", $0) }.joined() + "> ").utf8))
                }
                if let parent = links.first(where: { $0.child == ref })?.parent {
                    guard let target = mapping[parent] else { throw Failure.unsupported }
                    body.append(Data("/IRT \(target.object) \(target.generation) R /RT /R ".utf8))
                }
                body.append(Data("/P \(page.object) \(page.generation) R >>".utf8))
            } else { body = try render(value, depth: depth + 1) }
            var parser = PDFReplyWriter.Parser(bytes: rewritten.bytes, index: value.range.upperBound)
            if (try? parser.token()) == "stream" {
                guard case .dictionary = value.kind, let rawLength = value["Length"],
                      let length = try rewritten.resolved(rawLength).integer, length >= 0, length <= 10_000_000 else { throw Failure.unsupported }
                if parser.index < rewritten.bytes.count, rewritten.bytes[parser.index] == 13 { parser.index += 1 }
                guard parser.index < rewritten.bytes.count, rewritten.bytes[parser.index] == 10 else { throw Failure.unsupported }
                parser.index += 1
                guard length <= rewritten.bytes.count - parser.index else { throw Failure.unsupported }
                let end = parser.index + length
                body.append(Data("\nstream\n".utf8)); body.append(contentsOf: rewritten.bytes[parser.index..<end]); body.append(Data("\nendstream".utf8))
                parser.index = end
                guard try parser.token() == "endstream", try parser.token() == "endobj" else { throw Failure.unsupported }
            } else {
                parser.index = value.range.upperBound
                guard try parser.token() == "endobj" else { throw Failure.unsupported }
            }
            objects[destination] = body
        }
        for (index, page) in pages.enumerated() {
            var annotationRefs = [Ref]()
            for annotation in page.annotations where annotation.type != "Popup" {
                let id = ObjectIdentifier(annotation), temp = refs[id]!, ref = mapping[temp]!
                annotationRefs.append(ref)
                if existing[id] == nil { try copy(temp, to: ref, page: pageRefs[index], depth: 0) }
            }
            let sourcePage = try file.object(pageRefs[index])
            var old: [Value] = []
            if let annots = sourcePage["Annots"] {
                guard let values = try file.resolved(annots).array else { throw Failure.unsupported }; old = values
            }
            var originalRefs = [Ref]()
            for value in old {
                guard let ref = value.reference else { throw Failure.unsupported }
                originalRefs.append(ref)
                if try file.object(ref)["Subtype"]?.name == "Popup" {
                    guard let parent = try file.object(ref)["Parent"]?.reference else { throw Failure.unsupported }
                    if retained.contains(parent) { annotationRefs.append(ref) }
                }
            }
            if annotationRefs != originalRefs {
                patches[pageRefs[index]] = ["Annots": "[ " + annotationRefs.map { "\($0.object) \($0.generation) R" }.joined(separator: " ") + " ]"]
            }
        }
        let result = try PDFReplyWriter.replacingDictionaries(file, patches: patches, objects: objects, incremental: true)
        guard result.starts(with: original), let reopened = PDFDocument(data: result), reopened.pageCount == pages.count,
              try PDFFormPreservation.snapshot(reopened) == forms else { throw Failure.unsupported }
        return result
    }

    /// Compare PDFKit's own before/after annotation projections, independently of indirect object numbering.
    private static func fingerprint(_ ref: Ref, in file: File) throws -> String {
        var ancestors = Set<Ref>(), remaining = 200_000
        func encode(_ value: Value, depth: Int = 0) throws -> Data {
            remaining -= 1; guard remaining > 0, depth < 64 else { throw Failure.unsupported }
            switch value.kind {
            case .reference(let ref):
                guard ancestors.insert(ref).inserted else { throw Failure.unsupported }
                defer { ancestors.remove(ref) }
                return try encode(file.object(ref), depth: depth + 1)
            case .dictionary(let entries):
                var result = Data("<<".utf8)
                for entry in entries.filter({ !["P", "Parent", "Popup", "IRT", "NM"].contains($0.name) }).sorted(by: { $0.name < $1.name }) {
                    result.append(Data("/\(entry.name) ".utf8)); result.append(try encode(entry.value, depth: depth + 1)); result.append(32)
                }
                result.append(Data(">>".utf8))
                var parser = PDFReplyWriter.Parser(bytes: file.bytes, index: value.range.upperBound)
                if (try? parser.token()) == "stream" {
                    guard let raw = value["Length"], let length = try file.resolved(raw).integer, length >= 0, length <= 10_000_000 else { throw Failure.unsupported }
                    if parser.index < file.bytes.count, file.bytes[parser.index] == 13 { parser.index += 1 }
                    guard parser.index < file.bytes.count, file.bytes[parser.index] == 10 else { throw Failure.unsupported }; parser.index += 1
                    guard length <= file.bytes.count - parser.index else { throw Failure.unsupported }
                    result.append(contentsOf: file.bytes[parser.index..<(parser.index + length)])
                }
                return result
            case .array(let entries):
                var result = Data("[".utf8)
                for entry in entries { result.append(try encode(entry, depth: depth + 1)); result.append(32) }
                result.append(93); return result
            default: return Data(file.bytes[value.range])
            }
        }
        return SHA256.hash(data: try encode(file.object(ref))).map { String(format: "%02x", $0) }.joined()
    }
}
