import PDFKit

/// Wrap the original vector streams. No rasterisation, font rewrite or content parsing is needed.
enum PDFPageSizing {
    typealias Ref = PDFReplyWriter.Reference
    typealias Value = PDFReplyWriter.Value
    struct Fit {
        let box: CGRect
        let scale: CGFloat
        let x: CGFloat
        let y: CGFloat
        func point(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + x, y: point.y * scale + y) }
        func rect(_ rect: CGRect) -> CGRect { CGRect(origin: point(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale)) }
    }
    static func fitting(crop: CGRect, rotation: Int, paper: CGSize) throws -> Fit {
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0,
              paper.width.isFinite, paper.height.isFinite, paper.width > 0, paper.height > 0, rotation % 90 == 0 else { throw PDFEditing.Failure.invalid }
        // Retain /Rotate: annotations and appearance streams keep their original orientation.
        let sideways = (rotation % 180 + 180) % 180 == 90
        let size = sideways ? CGSize(width: paper.height, height: paper.width) : paper
        let scale = min(size.width / crop.width, size.height / crop.height)
        return Fit(box: CGRect(origin: .zero, size: size), scale: scale,
                   x: (size.width - crop.width * scale) / 2 - crop.minX * scale,
                   y: (size.height - crop.height * scale) / 2 - crop.minY * scale)
    }
    static func apply(_ document: PDFDocument, graph: PDFCommentGraph, sourceData: Data?, paper: CGSize) throws -> Data {
        try PDFEditing.validate(document, assembly: true, allowSignatureChanges: graph.allowsSignatureChanges)
        let baseline: Data
        if let sourceData, (try? PDFReplyWriter.File(sourceData)) != nil { baseline = sourceData }
        else { baseline = try graph.serialize(document) }
        let file = try PDFReplyWriter.File(baseline), refs = try file.pages()
        guard refs.count == document.pageCount else { throw PDFEditing.Failure.invalid }
        var fits: [Ref: Fit] = [:], annotations: [Ref: Fit] = [:]
        var patches: [Ref: [String: String]] = [:], objects: [Ref: Data] = [:]
        var next = max(file.trailer["Size"]?.integer ?? 0, (file.offsets.keys.map(\.object).max() ?? 0) + 1)
        func raw(_ value: Value) -> Data { Data(file.bytes[value.range]) }
        func text(_ value: Value) -> String { String(decoding: raw(value), as: UTF8.self) }
        func refText(_ ref: Ref) -> String { "\(ref.object) \(ref.generation) R" }
        func stream(_ content: String) -> Ref {
            let ref = Ref(object: next, generation: 0); next += 1
            objects[ref] = Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8); return ref
        }
        for (index, ref) in refs.enumerated() {
            guard let page = document.page(at: index) else { throw PDFEditing.Failure.invalid }
            let fit = try fitting(crop: page.bounds(for: .cropBox), rotation: page.rotation, paper: paper)
            fits[ref] = fit
            let value = try file.object(ref)
            var contents = ""
            if let original = value["Contents"] {
                let resolved = try file.resolved(original)
                if let array = resolved.array { contents = array.map(text).joined(separator: " ") }
                else { guard original.reference != nil else { throw PDFEditing.Failure.unsupported }; contents = text(original) }
            }
            let crop = page.bounds(for: .cropBox)
            let prefix = stream("q \(n(fit.scale)) 0 0 \(n(fit.scale)) \(n(fit.x)) \(n(fit.y)) cm \(n(crop.minX)) \(n(crop.minY)) \(n(crop.width)) \(n(crop.height)) re W n\n")
            let suffix = stream("Q\n")
            var entries = ["Contents": "[ \(refText(prefix)) \(contents) \(refText(suffix)) ]", "Rotate": "\(page.rotation)"]
            for key in ["MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"] { entries[key] = box(fit.box) }
            patches[ref] = entries
            if let annots = value["Annots"], let array = try file.resolved(annots).array {
                for annotation in array {
                    guard let ref = annotation.reference else { throw PDFEditing.Failure.unsupported }
                    if let other = annotations[ref], other.scale != fit.scale || other.x != fit.x || other.y != fit.y { throw PDFEditing.Failure.unsupported }
                    annotations[ref] = fit
                }
            }
        }
        // Rewrite only geometry and destinations; preserve literal strings and every untouched byte.
        var visitedDestinations = Set<Ref>()
        func destination(_ value: Value) throws -> Data {
            if let ref = value.reference {
                if visitedDestinations.insert(ref).inserted { objects[ref] = try destination(file.object(ref)) }
                return raw(value)
            }
            if let values = value.array, values.count >= 2, let target = values[0].reference, let fit = fits[target], let mode = values[1].name {
                var tokens = values.map(text)
                func coordinate(_ index: Int, offset: CGFloat) {
                    if values.indices.contains(index), let number = values[index].number { tokens[index] = n(CGFloat(number) * fit.scale + offset) }
                }
                switch mode {
                case "XYZ":
                    coordinate(2, offset: fit.x); coordinate(3, offset: fit.y)
                    if values.count > 4, let zoom = values[4].number, zoom > 0 { tokens[4] = n(CGFloat(zoom) / fit.scale) }
                case "FitH", "FitBH": coordinate(2, offset: fit.y)
                case "FitV", "FitBV": coordinate(2, offset: fit.x)
                case "FitR": coordinate(2, offset: fit.x); coordinate(3, offset: fit.y); coordinate(4, offset: fit.x); coordinate(5, offset: fit.y)
                default: break
                }
                return Data(("[ " + tokens.joined(separator: " ") + " ]").utf8)
            }
            if value["D"] != nil { return try replacing(value, entries: ["D": destination(value["D"]!)]) }
            return raw(value) // Named destinations are updated in their name tree below.
        }
        func replacing(_ value: Value, entries: [String: Data]) throws -> Data {
            guard case .dictionary = value.kind else { throw PDFEditing.Failure.unsupported }
            var output = Data("<< ".utf8)
            for entry in value.entries {
                if let replacement = entries[entry.name] { output.append(Data("/\(entry.name) ".utf8)); output.append(replacement) }
                else { output.append(contentsOf: file.bytes[entry.range]) }
                output.append(32)
            }
            output.append(Data(">>".utf8)); return output
        }
        func navigation(_ value: Value, depth: Int = 0) throws -> Data {
            guard depth < 64 else { throw PDFEditing.Failure.unsupported }
            if case .dictionary = value.kind {
                var changes: [String: Data] = [:]
                for entry in value.entries {
                    if entry.name == "Dest" || (entry.name == "D" && value["S"]?.name == "GoTo") { changes[entry.name] = try destination(entry.value) }
                    else if case .dictionary = entry.value.kind { changes[entry.name] = try navigation(entry.value, depth: depth + 1) }
                }
                return changes.isEmpty ? raw(value) : try replacing(value, entries: changes)
            }
            return raw(value)
        }
        for ref in file.offsets.keys where patches[ref] == nil && objects[ref] == nil {
            let value = try file.object(ref)
            guard case .dictionary = value.kind else { continue }
            // Never replace stream dictionaries without their stream bytes.
            let nav = try navigation(value)
            var replacement = value
            var changes: [String: Data] = [:]
            if let fit = annotations[ref] {
                if let rect = value["Rect"]?.array, rect.count == 4, let numbers = numbers(rect) {
                    changes["Rect"] = Data(box(fit.rect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]))).utf8)
                }
                for key in ["QuadPoints", "Vertices", "L", "CL"] {
                    if let values = value[key]?.array, let numbers = numbers(values), numbers.count % 2 == 0 {
                        changes[key] = Data(("[ " + stride(from: 0, to: numbers.count, by: 2).map { i in let p = fit.point(CGPoint(x: numbers[i], y: numbers[i + 1])); return "\(n(p.x)) \(n(p.y))" }.joined(separator: " ") + " ]").utf8)
                    }
                }
                if let lists = value["InkList"]?.array {
                    let transformed = try lists.map { item -> String in
                        guard let values = item.array, let numbers = numbers(values), numbers.count % 2 == 0 else { throw PDFEditing.Failure.unsupported }
                        return "[ " + stride(from: 0, to: numbers.count, by: 2).map { i in let p = fit.point(CGPoint(x: numbers[i], y: numbers[i + 1])); return "\(n(p.x)) \(n(p.y))" }.joined(separator: " ") + " ]"
                    }
                    changes["InkList"] = Data(("[ " + transformed.joined(separator: " ") + " ]").utf8)
                }
            }
            if !changes.isEmpty {
                // Merge geometry with a destination rewrite without converting binary strings to UTF-8.
                var parser = PDFReplyWriter.Parser(bytes: Array(nav), index: 0)
                replacement = try parser.value()
                var result = Data("<< ".utf8)
                for entry in replacement.entries {
                    if let change = changes[entry.name] { result.append(Data("/\(entry.name) ".utf8)); result.append(change) }
                    else { result.append(contentsOf: Array(nav)[entry.range]) }
                    result.append(32)
                }
                result.append(Data(">>".utf8)); objects[ref] = result
            } else if nav != raw(value) { objects[ref] = nav }
        }
        let catalogRef = file.trailer["Root"]!.reference!, catalog = try file.object(catalogRef)
        var catalogChanges: [String: Data] = [:]
        if let legacy = catalog["Dests"] {
            let value = try file.resolved(legacy)
            let changes = try Dictionary(uniqueKeysWithValues: value.entries.map { ($0.name, try destination($0.value)) })
            let output = try replacing(value, entries: changes)
            if let ref = legacy.reference { objects[ref] = output }
            else { catalogChanges["Dests"] = output }
        }
        var trees = Set<Ref>()
        func nameTree(_ value: Value, depth: Int = 0) throws -> Data {
            guard depth < 64 else { throw PDFEditing.Failure.unsupported }
            if let ref = value.reference, !trees.insert(ref).inserted { throw PDFEditing.Failure.unsupported }
            let node = try file.resolved(value)
            var changes: [String: Data] = [:]
            if let names = node["Names"], let pairs = try file.resolved(names).array {
                guard pairs.count % 2 == 0 else { throw PDFEditing.Failure.unsupported }
                var output = Data("[ ".utf8)
                for (index, pair) in pairs.enumerated() { output.append(index % 2 == 0 ? raw(pair) : try destination(pair)); output.append(32) }
                output.append(Data("]".utf8))
                if let ref = names.reference { objects[ref] = output }
                else { changes["Names"] = output }
            }
            if let kids = node["Kids"], let children = try file.resolved(kids).array {
                var output = Data("[ ".utf8)
                for child in children {
                    let rewritten = try nameTree(child, depth: depth + 1)
                    if let ref = child.reference { objects[ref] = rewritten; output.append(raw(child)) }
                    else { output.append(rewritten) }
                    output.append(32)
                }
                output.append(Data("]".utf8))
                if let ref = kids.reference { objects[ref] = output }
                else { changes["Kids"] = output }
            }
            return try replacing(node, entries: changes)
        }
        if let names = catalog["Names"] {
            let dictionary = try file.resolved(names)
            if let tree = dictionary["Dests"] {
                let rewritten = try nameTree(tree)
                if let ref = tree.reference { objects[ref] = rewritten }
                else {
                    let output = try replacing(dictionary, entries: ["Dests": rewritten])
                    if let ref = names.reference { objects[ref] = output }
                    else { catalogChanges["Names"] = output }
                }
            }
        }
        if !catalogChanges.isEmpty {
            // Catalog OpenAction may already have been rewritten by navigation().
            let data = objects[catalogRef] ?? raw(catalog), bytes = Array(data)
            var parser = PDFReplyWriter.Parser(bytes: bytes, index: 0)
            let value = try parser.value()
            var output = Data("<< ".utf8)
            for entry in value.entries {
                if let change = catalogChanges[entry.name] { output.append(Data("/\(entry.name) ".utf8)); output.append(change) }
                else { output.append(contentsOf: bytes[entry.range]) }
                output.append(32)
            }
            output.append(Data(">>".utf8)); objects[catalogRef] = output
        }
        let bytes = try PDFReplyWriter.replacingDictionaries(file, patches: patches, objects: objects)
        guard let check = PDFDocument(data: bytes), check.pageCount == document.pageCount else { throw PDFEditing.Failure.invalid }
        for index in refs.indices {
            guard let page = check.page(at: index), let original = document.page(at: index), let fit = fits[refs[index]],
                  page.string == original.string, page.rotation == original.rotation,
                  abs(page.bounds(for: .cropBox).width - fit.box.width) < 0.01,
                  abs(page.bounds(for: .cropBox).height - fit.box.height) < 0.01,
                  page.annotations.filter({ $0.type != "Popup" }).count == original.annotations.filter({ $0.type != "Popup" }).count else { throw PDFEditing.Failure.invalid }
        }
        return bytes
    }
    private static func numbers(_ values: [Value]) -> [CGFloat]? {
        let result = values.compactMap { $0.number.map { CGFloat($0) } }
        return result.count == values.count ? result : nil
    }
    private static func n(_ value: CGFloat) -> String { String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    private static func box(_ rect: CGRect) -> String { "[ \(n(rect.minX)) \(n(rect.minY)) \(n(rect.maxX)) \(n(rect.maxY)) ]" }
}
