import PDFKit

/// Page objects, rather than whole-document snapshots, are retained by undo.
enum PDFPageAssembly {
    static let maximumImportBytes = 256 * 1024 * 1024

    static func pages(_ document: PDFDocument) -> [PDFPage] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }
    }

    static func imported(_ urls: [URL], allowSignatureChanges: Bool = false) throws -> ([PDFPage], [PDFCommentGraph], [PDFDocument]) {
        guard !urls.isEmpty, urls.count <= 50, urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else {
            throw Failure.files
        }
        var size = 0, pages: [PDFPage] = [], graphs: [PDFCommentGraph] = [], sources: [PDFDocument] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumImportBytes + 1
            guard count > 0, count <= maximumImportBytes - size else { throw Failure.size }
            size += count
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count <= maximumImportBytes, let source = PDFDocument(data: bytes) else { throw Failure.files }
            try PDFEditing.validate(source, assembly: true, allowSignatureChanges: allowSignatureChanges)
            guard source.allowsCopying, pages.count + source.pageCount <= 10000 else { throw Failure.size }
            let graph = PDFCommentGraph(document: source, sourceData: bytes, allowSignatureChanges: allowSignatureChanges)
            // Refuse files whose reply graph cannot survive even a no-op write.
            _ = try graph.serialize(source)
            pages += self.pages(source); graphs.append(graph); sources.append(source)
        }
        return (pages, graphs, sources)
    }

    static func apply(_ pages: [PDFPage], in document: PDFDocument, graph: PDFCommentGraph, sourceData: Data? = nil) throws -> Data {
        try PDFEditing.validate(document, assembly: true, allowSignatureChanges: graph.allowsSignatureChanges)
        guard !pages.isEmpty, pages.count <= 10000, Set(pages.map(ObjectIdentifier.init)).count == pages.count else { throw PDFEditing.Failure.invalid }
        let before = self.pages(document)
        let contents = pages.map { $0.string }
        let rotations = pages.map { $0.rotation }
        let crops = pages.map { $0.bounds(for: .cropBox) }
        let annotations = pages.map { $0.annotations.filter { $0.type != "Popup" }.count }
        let navigation = try Navigation(document: document, pages: pages)
        let reordering = before.count == pages.count && Set(before.map(ObjectIdentifier.init)) == Set(pages.map(ObjectIdentifier.init))
        // Normalise before changing page indices; writing afterwards can corrupt tagged-text lookup in PDFKit.
        let orderedBytes: Data?
        if reordering {
            let baseline: Data
            if let sourceData, (try? PDFReplyWriter.File(sourceData)) != nil { baseline = sourceData }
            else { baseline = try graph.serialize(document) }
            orderedBytes = try reordered(baseline, before: before, after: pages)
        } else { orderedBytes = nil }
        replace(with: pages, in: document)
        navigation.restore(in: document)
        do {
            let bytes = try orderedBytes ?? graph.serialize(document)
            guard let check = PDFDocument(data: bytes), check.pageCount == pages.count else { throw PDFEditing.Failure.invalid }
            for index in pages.indices {
                guard let page = check.page(at: index), page.string == contents[index], page.rotation == rotations[index],
                      Self.sameBounds(page.bounds(for: .cropBox), crops[index]), page.annotations.filter({ $0.type != "Popup" }).count == annotations[index] else { throw PDFEditing.Failure.invalid }
            }
            try navigation.verify(check, pages: pages)
            return bytes
        } catch {
            replace(with: before, in: document)
            navigation.restore(in: document)
            throw error
        }
    }

    static func rotated(_ rotations: [(PDFPage, Int)], in document: PDFDocument, graph: PDFCommentGraph, sourceData: Data?) throws -> Data {
        let baseline: Data
        if let sourceData, (try? PDFReplyWriter.File(sourceData)) != nil { baseline = sourceData }
        else { baseline = try graph.serialize(document) }
        let file = try PDFReplyWriter.File(baseline), refs = try file.pages()
        guard refs.count == document.pageCount else { throw PDFEditing.Failure.invalid }
        var patches: [PDFReplyWriter.Reference: [String: String]] = [:]
        for (page, rotation) in rotations {
            let index = document.index(for: page)
            guard index != NSNotFound, refs.indices.contains(index), rotation % 90 == 0 else { throw PDFEditing.Failure.invalid }
            patches[refs[index]] = ["Rotate": "\((rotation % 360 + 360) % 360)"]
        }
        let bytes = try PDFReplyWriter.replacingDictionaries(file, patches: patches)
        guard let check = PDFDocument(data: bytes), check.pageCount == document.pageCount else { throw PDFEditing.Failure.invalid }
        for index in refs.indices {
            guard check.page(at: index)?.string == document.page(at: index)?.string else { throw PDFEditing.Failure.invalid }
        }
        return bytes
    }

    private static func sameBounds(_ left: CGRect, _ right: CGRect) -> Bool {
        zip([left.minX, left.minY, left.width, left.height], [right.minX, right.minY, right.width, right.height]).allSatisfy { abs($0 - $1) < 0.001 }
    }

    private static func reordered(_ data: Data, before: [PDFPage], after: [PDFPage]) throws -> Data {
        let file = try PDFReplyWriter.File(data), refs = try file.pages()
        guard refs.count == before.count, let catalog = file.trailer["Root"]?.reference,
              let root = try file.object(catalog)["Pages"]?.reference else { throw PDFEditing.Failure.invalid }
        let mapping = Dictionary(uniqueKeysWithValues: zip(before.map(ObjectIdentifier.init), refs))
        func reference(_ value: PDFReplyWriter.Reference) -> String { "\(value.object) \(value.generation) R" }
        var patches: [PDFReplyWriter.Reference: [String: String]] = [:]
        let ordered = try after.map { page -> PDFReplyWriter.Reference in
            guard let value = mapping[ObjectIdentifier(page)] else { throw PDFEditing.Failure.invalid }; return value
        }
        patches[root] = ["Kids": "[ " + ordered.map(reference).joined(separator: " ") + " ]", "Count": "\(after.count)"]
        for page in refs {
            var additions = ["Parent": reference(root)]
            let own = try file.object(page)
            for key in ["MediaBox", "CropBox", "Resources", "Rotate"] where own[key] == nil {
                var parent = own["Parent"]?.reference, visited = Set<PDFReplyWriter.Reference>()
                while let cursor = parent {
                    guard visited.insert(cursor).inserted, visited.count <= 64 else { throw PDFEditing.Failure.unsupported }
                    let value = try file.object(cursor)
                    if let inherited = value[key] {
                        guard let text = String(bytes: file.bytes[inherited.range], encoding: .utf8) else { throw PDFEditing.Failure.unsupported }
                        additions[key] = text; break
                    }
                    parent = value["Parent"]?.reference
                }
            }
            patches[page] = additions
        }
        return try PDFReplyWriter.replacingDictionaries(file, patches: patches)
    }

    /// PDFKit can replace destinations with stale page numbers during remove/insert.
    /// Capture the actual page objects first, then rebuild destinations after the final order exists.
    private struct Navigation {
        struct Anchor {
            let page: PDFPage
            let point: CGPoint
            let zoom: CGFloat
            init(_ destination: PDFDestination, pages: [PDFPage]) throws {
                guard let page = destination.page, pages.contains(where: { $0 === page }) else { throw PDFEditing.Failure.unsupported }
                self.page = page; point = destination.point; zoom = destination.zoom
            }
            var destination: PDFDestination { let value = PDFDestination(page: page, at: point); value.zoom = zoom; return value }
        }
        let root: PDFOutline?
        let sections: [(PDFOutline, Anchor, Bool)]
        let links: [(PDFAnnotation, Anchor, Int, Int)]
        init(document: PDFDocument, pages: [PDFPage]) throws {
            var sections: [(PDFOutline, Anchor, Bool)] = [], visited = 0
            func copy(_ node: PDFOutline, depth: Int) throws -> PDFOutline {
                visited += 1
                guard depth < 64, visited <= 10000 else { throw PDFEditing.Failure.unsupported }
                let value = PDFOutline(); value.label = node.label; value.isOpen = node.isOpen
                if let action = node.action as? PDFActionGoTo { sections.append((value, try Anchor(action.destination, pages: pages), true)) }
                else if let destination = node.destination { sections.append((value, try Anchor(destination, pages: pages), false)) }
                else { value.action = node.action }
                for index in 0..<node.numberOfChildren {
                    guard let child = node.child(at: index) else { throw PDFEditing.Failure.unsupported }
                    value.insertChild(try copy(child, depth: depth + 1), at: index)
                }
                return value
            }
            root = try document.outlineRoot.map { try copy($0, depth: 0) }
            self.sections = sections
            links = try pages.enumerated().flatMap { pageIndex, page in
                try page.annotations.filter { $0.type != "Popup" }.enumerated().compactMap { annotationIndex, annotation in
                    guard let action = annotation.action as? PDFActionGoTo else { return nil }
                    return (annotation, try Anchor(action.destination, pages: pages), pageIndex, annotationIndex)
                }
            }
        }
        func restore(in document: PDFDocument) {
            for (section, anchor, action) in sections {
                if action { section.action = PDFActionGoTo(destination: anchor.destination) }
                else { section.destination = anchor.destination }
            }
            document.outlineRoot = root
            for (link, anchor, _, _) in links { link.action = PDFActionGoTo(destination: anchor.destination) }
        }
        func verify(_ output: PDFDocument, pages: [PDFPage]) throws {
            func sameTarget(_ expected: PDFDestination?, _ actual: PDFDestination?) -> Bool {
                guard let expected else { return actual == nil }
                guard let expectedPage = expected.page, let actualPage = actual?.page,
                      let index = pages.firstIndex(where: { $0 === expectedPage }) else { return false }
                return output.index(for: actualPage) == index
            }
            func sameOutline(_ expected: PDFOutline, _ actual: PDFOutline) -> Bool {
                guard expected.label == actual.label, expected.numberOfChildren == actual.numberOfChildren,
                      sameTarget(expected.destination ?? (expected.action as? PDFActionGoTo)?.destination,
                                 actual.destination ?? (actual.action as? PDFActionGoTo)?.destination) else { return false }
                for index in 0..<expected.numberOfChildren {
                    guard let left = expected.child(at: index), let right = actual.child(at: index), sameOutline(left, right) else { return false }
                }
                return true
            }
            if let root, root.numberOfChildren > 0 {
                guard let actual = output.outlineRoot, sameOutline(root, actual) else { throw PDFEditing.Failure.invalid }
            }
            for (_, anchor, pageIndex, annotationIndex) in links {
                let annotations = output.page(at: pageIndex)?.annotations.filter { $0.type != "Popup" } ?? []
                guard annotations.indices.contains(annotationIndex),
                      let actual = annotations[annotationIndex].action as? PDFActionGoTo,
                      sameTarget(anchor.destination, actual.destination) else { throw PDFEditing.Failure.invalid }
            }
        }
    }

    private static func replace(with after: [PDFPage], in document: PDFDocument) {
        // Moving one page must not destroy the outline's destinations or the remaining page identities.
        for (index, page) in after.enumerated() {
            let existing = self.pages(document).firstIndex { $0 === page } ?? NSNotFound
            if existing == index { continue }
            if existing != NSNotFound { document.removePage(at: existing) }
            document.insert(page, at: index)
        }
        while document.pageCount > after.count { document.removePage(at: document.pageCount - 1) }
    }

    enum Failure: LocalizedError {
        case files, size, draft, stale
        var errorDescription: String? {
            switch self {
            case .files: return "Drop local PDF files to insert their pages."
            case .size: return "Add at most 50 PDFs, 256 MB and 10,000 pages at a time."
            case .draft: return "Finish or cancel the comment draft before arranging pages."
            case .stale: return "The document changed during the drag. Please drag the page again."
            }
        }
    }
}
