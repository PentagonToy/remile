import Foundation

extension HomeModel {
    var automationTarget: UUID? { texProject?.identity ?? (reader.url == nil ? nil : reader.identity) }
    var automationDescription: [String: Any]? {
        guard let target = automationTarget else { return nil }
        return ["target": target.uuidString, "kind": texProject == nil ? "document" : "latex-local", "path": texProject?.root.path ?? reader.url?.path ?? "", "dirty": texProject?.dirty ?? reader.dirty]
    }
}
