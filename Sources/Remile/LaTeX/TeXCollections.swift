import Foundation
import CryptoKit
import AppKit

/// Sidebar organisation only. Source paths and compiler inputs never change.
enum TeXCollections {
    struct Group: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var parent: UUID? = nil
        var paths: [String] = []
        var expanded = true
    }
    static func location(_ root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Collections/" + key + ".json")
    }
    static func read(_ root: URL) -> [Group] {
        guard let data = try? Data(contentsOf: location(root)), data.count < 2_000_000 else { return [] }
        return (try? JSONDecoder().decode([Group].self, from: data)) ?? []
    }
    static func write(_ groups: [Group], root: URL) throws {
        let url = location(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(groups).write(to: url, options: .atomic)
    }
    static func assigning(_ paths: [String], to id: UUID?, groups: [Group], allowed: Set<String>) -> [Group] {
        let paths = Set(paths).intersection(allowed)
        guard id == nil || groups.contains(where: { $0.id == id }) else { return groups }
        return groups.map { group in
            var updated = group
            updated.paths = Set(group.paths).subtracting(paths).union(group.id == id ? paths : []).sorted()
            return updated
        }
    }
    static func moving(_ ids: Set<UUID>, under parent: UUID?, groups: [Group]) -> [Group]? {
        let known = Set(groups.map(\.id))
        guard ids.isSubset(of: known), parent == nil || known.contains(parent!) else { return nil }
        var ancestors = Set<UUID>(), cursor = parent
        while let id = cursor {
            guard ancestors.insert(id).inserted, !ids.contains(id) else { return nil }
            cursor = groups.first(where: { $0.id == id })?.parent
        }
        return groups.map { group in
            var item = group, cursor = group.parent, seen = Set<UUID>(), hasSelectedAncestor = false
            while let id = cursor, seen.insert(id).inserted { if ids.contains(id) { hasSelectedAncestor = true; break }; cursor = groups.first(where: { $0.id == id })?.parent }
            if ids.contains(item.id) && !hasSelectedAncestor { item.parent = parent }; return item
        }
    }
    static func removing(_ id: UUID, groups: [Group]) -> [Group] {
        let parent = groups.first(where: { $0.id == id })?.parent
        return groups.filter { $0.id != id }.map { group in var item = group; if item.parent == id { item.parent = parent }; return item }
    }

}

extension TeXProject {
    func addCollection(parent: UUID? = nil) {
        guard !compiling else { return }
        newItemError = nil; newItemDraft = NewItemDraft(kind: .collection(parent))
    }
    func updateCollections(_ value: [TeXCollections.Group]) {
        do { try TeXCollections.write(value, root: root); collections = value }
        catch { message = "Could not save the sidebar arrangement: " + error.localizedDescription }
    }
    func collect(_ path: String, in id: UUID?) { updateCollections(TeXCollections.assigning([path], to: id, groups: collections, allowed: Set(treeFiles))) }
    func chooseCollectionFiles(_ id: UUID) {
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel(); panel.title = "Add files to " + collection.name; panel.prompt = "Add"; panel.directoryURL = root
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let selected = Set(panel.urls.map(\.standardizedFileURL))
        let paths = treeFiles.filter { selected.contains(root.appendingPathComponent($0).standardizedFileURL) }
        updateCollections(TeXCollections.assigning(paths, to: id, groups: collections, allowed: Set(treeFiles)))
    }
}
