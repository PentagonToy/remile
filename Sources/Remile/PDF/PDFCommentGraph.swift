import PDFKit

// Own the annotation identity/reply relationship separately from PDFKit's lossy writer.
final class PDFCommentGraph {
    private(set) var parents: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var names: [ObjectIdentifier: String] = [:]
    private var importIsComplete = true
    private weak var sourceDocument: PDFDocument?

    let allowsSignatureChanges: Bool
    private(set) var signaturePreservedData: Data?
    private let signed: Bool
    private let signatureSource: PDFSignedAnnotations.Source?
    private var signedWriter: PDFSignedAnnotations?
    private var signatureError: Error?

    init(document: PDFDocument, sourceData: Data? = nil, allowSignatureChanges: Bool = false) {
        allowsSignatureChanges = allowSignatureChanges
        signed = PDFFormPreservation.hasDigitalSignature(document)
        signatureSource = signed ? sourceData.map { PDFSignedAnnotations.Source(document: document, data: $0) } : nil
        sourceDocument = document
        // PDFKit can omit an outline that has never been materialised before its first write.
        _ = document.outlineRoot
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let rawPage = page.pageRef, let pageDictionary = rawPage.dictionary else { importIsComplete = false; continue }
            var rawArray: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &rawArray), let rawArray else {
                if !page.annotations.isEmpty { importIsComplete = false }
                continue
            }
            var mappings: [(PDFAnnotation, CGPDFDictionaryRef)] = []
            let annotations = page.annotations.filter { $0.type != "Popup" }
            for position in 0..<CGPDFArrayGetCount(rawArray) {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(rawArray, position, &dictionary), let dictionary else { importIsComplete = false; continue }
                if Self.name("Subtype", dictionary) == "Popup" { continue }
                guard mappings.count < annotations.count else { importIsComplete = false; continue }
                let annotation = annotations[mappings.count]
                guard Self.name("Subtype", dictionary) == annotation.type else { importIsComplete = false; continue }
                mappings.append((annotation, dictionary))
            }
            guard mappings.count == annotations.count else { importIsComplete = false; continue }
            var identities: [UInt: ObjectIdentifier] = [:]
            for (annotation, dictionary) in mappings {
                let key = UInt(bitPattern: dictionary.rawValue)
                if identities[key] != nil { importIsComplete = false }
                identities[key] = ObjectIdentifier(annotation)
            }
            for (annotation, dictionary) in mappings {
                let identity = ObjectIdentifier(annotation)
                var rawName: CGPDFStringRef?
                if CGPDFDictionaryGetString(dictionary, "NM", &rawName), let rawName,
                   let text = CGPDFStringCopyTextString(rawName) { names[identity] = text as String }
                else { names[identity] = UUID().uuidString }
                var parent: CGPDFDictionaryRef?
                var rawParent: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, "IRT", &rawParent) {
                    let relation = Self.name("RT", dictionary)
                    guard CGPDFDictionaryGetDictionary(dictionary, "IRT", &parent), let parent,
                          let parentID = identities[UInt(bitPattern: parent.rawValue)], relation == nil || relation == "R" else {
                        importIsComplete = false; continue
                    }
                    parents[identity] = parentID
                }
            }
        }
    }

    func add(_ annotation: PDFAnnotation, parent: PDFAnnotation?) {
        let id = ObjectIdentifier(annotation)
        names[id] = names[id] ?? UUID().uuidString
        if let parent { parents[id] = ObjectIdentifier(parent) }
    }
    func remove(_ annotation: PDFAnnotation) {
        parents.removeValue(forKey: ObjectIdentifier(annotation))
        // Keep its stable name for redo; no full PDF snapshots are retained.
    }
    func parent(of annotation: PDFAnnotation) -> ObjectIdentifier? { parents[ObjectIdentifier(annotation)] }

    /// Imported pages keep their annotation objects, so replies can retain their actual parents.
    func merge(_ other: PDFCommentGraph) throws {
        guard other.importIsComplete else { throw PDFReplyWriter.Failure.unsupported }
        var used = Set(names.values)
        for (id, name) in other.names where names[id] == nil {
            let unique = used.contains(name) ? UUID().uuidString : name
            names[id] = unique; used.insert(unique)
        }
        for (child, parent) in other.parents { parents[child] = parent }
    }

    private func prepareSignedWriter() throws {
        guard signed, signedWriter == nil else { return }
        if let signatureError { throw signatureError }
        do {
            guard let signatureSource else { throw PDFSignedAnnotations.Failure.unsupported }
            signedWriter = try PDFSignedAnnotations(source: signatureSource)
        } catch { signatureError = error; throw error }
    }
    func validateAnnotationSave() throws {
        if signed, !allowsSignatureChanges { try prepareSignedWriter() }
    }

    func serialize(_ document: PDFDocument) throws -> Data {
        signaturePreservedData = nil
        do { try prepareSignedWriter() } catch { if !allowsSignatureChanges { throw error } }
        let forms = try PDFFormPreservation.snapshot(document)
        guard sourceDocument === document, importIsComplete, let bytes = document.dataRepresentation() else { throw PDFReplyWriter.Failure.unsupported }
        let file = try PDFReplyWriter.File(bytes)
        let pages = try file.pages()
        guard pages.count == document.pageCount, let provider = CGDataProvider(data: bytes as CFData),
              let outputDocument = CGPDFDocument(provider) else { throw PDFReplyWriter.Failure.unsupported }
        var refs: [ObjectIdentifier: PDFReplyWriter.Reference] = [:]
        var pageIndices: [ObjectIdentifier: Int] = [:]
        for (index, pageRef) in pages.enumerated() {
            guard let page = document.page(at: index) else { throw PDFReplyWriter.Failure.unsupported }
            let annotations = page.annotations.filter { $0.type != "Popup" }
            let outputRefs = try file.annotations(on: pageRef)
            guard let rawPage = outputDocument.page(at: index + 1), let dictionary = rawPage.dictionary else { throw PDFReplyWriter.Failure.unsupported }
            var rawArray: CGPDFArrayRef?
            var outputAnnotations: [CGPDFDictionaryRef] = []
            if CGPDFDictionaryGetArray(dictionary, "Annots", &rawArray), let rawArray {
                for position in 0..<CGPDFArrayGetCount(rawArray) {
                    var annotation: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(rawArray, position, &annotation), let annotation else { throw PDFReplyWriter.Failure.unsupported }
                    if Self.name("Subtype", annotation) != "Popup" { outputAnnotations.append(annotation) }
                }
            }
            guard annotations.count == outputRefs.count, outputAnnotations.count == annotations.count else { throw PDFReplyWriter.Failure.unsupported }
            for (position, pair) in zip(annotations, outputRefs).enumerated() {
                let (annotation, ref) = pair
                var rawText: CGPDFStringRef?
                let outputText: String?
                if CGPDFDictionaryGetString(outputAnnotations[position], "Contents", &rawText), let rawText,
                   let text = CGPDFStringCopyTextString(rawText) { outputText = text as String }
                else { outputText = nil }
                // Equal rectangles alone are not enough: replies commonly share the parent's icon position.
                guard (outputText ?? "") == (annotation.contents ?? "") else { throw PDFReplyWriter.Failure.unsupported }
                let value = try file.object(ref)
                guard value["Subtype"]?.name == annotation.type,
                      let rect = value["Rect"]?.array, rect.count == 4,
                      let x = rect[0].number, let y = rect[1].number, let maxX = rect[2].number, let maxY = rect[3].number else { throw PDFReplyWriter.Failure.unsupported }
                func matches(_ bounds: CGRect) -> Bool {
                    abs(bounds.minX - annotation.bounds.minX) < 0.01 && abs(bounds.minY - annotation.bounds.minY) < 0.01 &&
                    abs(bounds.maxX - annotation.bounds.maxX) < 0.01 && abs(bounds.maxY - annotation.bounds.maxY) < 0.01
                }
                let stored = CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
                // PDFKit presents Text notes as a 24pt icon at the stored rectangle's top-left.
                guard matches(stored) || (annotation.type == "Text" && matches(CGRect(x: x, y: maxY - 24, width: 24, height: 24))) else { throw PDFReplyWriter.Failure.unsupported }
                refs[ObjectIdentifier(annotation)] = ref
                pageIndices[ObjectIdentifier(annotation)] = index
            }
        }
        var links: [PDFReplyWriter.Link] = []
        for (child, parent) in parents {
            // Undo can temporarily remove imported pages. Keep their relationships for redo.
            guard refs[child] != nil else { continue }
            guard let childRef = refs[child], let parentRef = refs[parent], pageIndices[child] == pageIndices[parent] else { throw PDFReplyWriter.Failure.unsupported }
            var visited: Set<ObjectIdentifier> = [child]
            var cursor: ObjectIdentifier? = parent
            while let id = cursor {
                guard visited.insert(id).inserted else { throw PDFReplyWriter.Failure.unsupported }
                cursor = parents[id]
            }
            links.append(.init(child: childRef, parent: parentRef))
        }
        var outputNames: [PDFReplyWriter.Reference: String] = [:]
        for (id, ref) in refs { if let name = names[id] { outputNames[ref] = name } }
        signaturePreservedData = nil
        if let signedWriter {
            do {
                let preserved = try signedWriter.serialize(document, rewritten: file, refs: refs, names: outputNames, links: links)
                signaturePreservedData = preserved
                return preserved
            } catch { if !allowsSignatureChanges { throw error } }
        }
        let result = try PDFReplyWriter.write(file, links: links, names: outputNames)
        if forms != nil, !(signed && allowsSignatureChanges) {
            guard let reopened = PDFDocument(data: result), try PDFFormPreservation.snapshot(reopened) == forms else { throw PDFReplyWriter.Failure.unsupported }
        }
        return result
    }

    private static func name(_ key: String, _ dictionary: CGPDFDictionaryRef) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
