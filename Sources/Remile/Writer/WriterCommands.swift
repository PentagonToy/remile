import Foundation
import AppKit

@MainActor enum WriterCommands {
    private static func page(_ value: WriterPageStyle) -> [String: Any] {
        ["header": value.header, "footer": value.footer, "topLine": value.topLine, "bottomLine": value.bottomLine, "pageNumbers": value.pageNumbers, "columns": value.columnCount]
    }
    static func handle(_ request: EditorBridge.Request, model: WriterModel) -> [String: Any] {
        let hash = SourceDigest.sha256(model.storage.string + model.revision.uuidString)
        do {
            switch request.operation {
            case "status": return ["ok": true, "kind": "writer", "target": model.identity.uuidString, "path": model.url?.path ?? "", "dirty": model.dirty, "pages": model.pages, "paper": model.paper, "landscape": model.landscape, "objects": model.objects.count, "zoom": model.zoom, "rulers": model.showRulers, "page": page(model.pageStyle), "sha256": hash]
            case "writer-page":
                var style = model.pageStyle
                let editing = request.header != nil || request.footer != nil || request.topLine != nil || request.bottomLine != nil || request.pageNumbers != nil || request.columns != nil
                if editing {
                    guard request.expectedSHA256 == hash else { throw ReferenceFailure("Writer changed. Read it again before editing.") }
                    if let value = request.header { style.header = value }
                    if let value = request.footer { style.footer = value }
                    if let value = request.topLine { style.topLine = value }
                    if let value = request.bottomLine { style.bottomLine = value }
                    if let value = request.pageNumbers { style.pageNumbers = value }
                    if let value = request.columns {
                        guard (1...2).contains(value) else { throw ReferenceFailure("Choose 1 or 2 columns.") }
                        style.columns = value
                    }
                    guard style.valid else { throw ReferenceFailure("Use header and footer text up to 200 characters on one line.") }
                    model.setPageStyle(style)
                }
                return ["ok": true, "page": page(model.pageStyle), "sha256": SourceDigest.sha256(model.storage.string + model.revision.uuidString)]
            case "writer-object":
                guard let id = request.object, var item = model.objects.first(where: { $0.id == id }) else { throw ReferenceFailure("Choose an object ID from read.") }
                if request.wrap != nil || request.locked != nil {
                    guard request.expectedSHA256 == hash else { throw ReferenceFailure("Writer changed. Read it again before editing.") }
                    if let value = request.wrap { item.wrapsText = value }
                    if let value = request.locked { item.locked = value }
                    model.update(item)
                }
                return ["ok": true, "id": id.uuidString, "wrap": item.wrapsText == true, "locked": item.locked == true, "sha256": SourceDigest.sha256(model.storage.string + model.revision.uuidString)]
            case "writer-view":
                if let zoom = request.zoom {
                    guard zoom.isFinite, (0.25...2).contains(zoom) else { throw ReferenceFailure("Choose zoom between 0.25 and 2.") }
                    model.setZoom(zoom)
                }
                if request.fit == true { model.fitWidth() }
                if let rulers = request.rulers { model.showRulers = rulers }
                return ["ok": true, "zoom": model.zoom, "rulers": model.showRulers]
            case "read":
                let objects = try model.objects.map { object -> [String: Any] in
                    var copy = object; copy.imageData = nil
                    var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as! [String: Any]
                    fields["imageBytes"] = object.imageData?.count ?? 0
                    return fields
                }
                return ["ok": true, "kind": "writer", "source": model.storage.string, "objects": objects, "page": page(model.pageStyle), "sha256": hash, "sha256Scope": "document revision", "dirty": model.dirty]
            case "replace":
                guard request.expectedSHA256 == hash, let source = request.source, source.utf16.count <= 200_000 else { throw ReferenceFailure("Writer changed. Read it again before replacing text.") }
                model.replaceBody(NSAttributedString(string: source, attributes: model.attributes))
                return ["ok": true, "saved": false, "sha256": SourceDigest.sha256(model.storage.string + model.revision.uuidString)]
            case "save":
                guard let url = model.url else { throw ReferenceFailure("Save once in Writer, or export to a new DOCX path.") }
                return ["ok": model.save(to: url), "message": model.error ?? ""]
            case "export":
                guard let path = request.output, path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw ReferenceFailure("Choose a new absolute output path.") }
                let url = URL(fileURLWithPath: path)
                if url.pathExtension.lowercased() == "docx" { try WriterArchive.encode(model).write(to: url, options: .atomic) }
                else if url.pathExtension.lowercased() == "pdf", let canvas = model.canvas { try canvas.pdf().write(to: url, options: .atomic) }
                else { throw ReferenceFailure("Use a DOCX or PDF output path.") }
                return ["ok": true, "output": path]
            default: throw ReferenceFailure("This operation is not available in Writer.")
            }
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
}
