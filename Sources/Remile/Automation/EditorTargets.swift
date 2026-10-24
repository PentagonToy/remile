import Foundation

extension HomeModel {
    var automationProjectID: String { texProject.flatMap { overleaf.connection(for: $0.root) }.map { OverleafProjectID.reference($0.projectID) } ?? "" }
    var automationTarget: UUID? { if page == .writer { return writer?.identity }; return texProject?.identity ?? (reader.url == nil ? nil : reader.identity) }
    var automationDescription: [String: Any]? {
        if page == .writer, let writer { return ["target": writer.identity.uuidString, "kind": "writer", "path": writer.url?.path ?? "", "dirty": writer.dirty] }
        guard let target = automationTarget else { return nil }
        return ["projectID": automationProjectID, "target": target.uuidString, "kind": texProject == nil ? "document" : "latex-local", "path": texProject?.root.path ?? reader.url?.path ?? "", "dirty": texProject?.dirty ?? reader.dirty]
    }
}
