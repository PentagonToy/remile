import Foundation

enum RemarkableFolderSelection {
    static func canonical(_ selected: Set<String>, items: [RemarkableCloudItem]) -> Set<String> {
        let parents = Dictionary(items.filter(\.isFolder).map { ($0.id, $0.parentID ?? "") }, uniquingKeysWith: { first, _ in first })
        return selected.filter { id in
            var parent = parents[id], seen: Set<String> = [id]
            while let current = parent, seen.insert(current).inserted {
                if selected.contains(current) { return false }
                parent = parents[current]
            }
            return true
        }
    }
    static func scopes(_ selected: Set<String>, items: [RemarkableCloudItem]) throws -> [RemarkableFolderScope] {
        let folders = Dictionary(items.filter(\.isFolder).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try canonical(selected, items: items).sorted().map { id in
            if id == RemarkableFolderScope.unfiledID { return RemarkableFolderScope(id: id, name: "Unfiled") }
            guard let folder = folders[id] else { throw ReferenceFailure("A selected folder is unavailable. Refresh the list.") }
            return RemarkableFolderScope(id: id, name: String(folder.title.prefix(500)))
        }
    }
    static func documents(_ scopes: [RemarkableFolderScope], items: [RemarkableCloudItem]) -> Set<String> {
        let selected = Set(scopes.map(\.id))
        let parents = Dictionary(items.filter(\.isFolder).map { ($0.id, $0.parentID ?? "") }, uniquingKeysWith: { first, _ in first })
        var cache: [String: Bool] = [:]
        func included(_ id: String) -> Bool {
            var current = id, seen = Set<String>(), path: [String] = []
            var result = false
            while seen.insert(current).inserted {
                if selected.contains(current) { result = true; break }
                if let value = cache[current] { result = value; break }
                guard let parent = parents[current] else { break }
                path.append(current); current = parent
            }
            for id in path { cache[id] = result }
            return result
        }
        return Set(items.filter { item in
            guard !item.isFolder else { return false }
            let parent = item.parentID ?? ""
            if parents[parent] == nil { return selected.contains(RemarkableFolderScope.unfiledID) }
            return included(parent)
        }.map(\.id))
    }
    static func updateIDs(_ library: ReferenceLibrary, records: [ReferenceRecord], items: [RemarkableCloudItem], hidden: Set<UUID> = []) -> Set<String> {
        let active = Set(records.filter { $0.trashed == nil && $0.collectionID.map(hidden.contains) != true }.compactMap { $0.remarkable?.id })
        guard let folders = library.remarkableFolders else { return active }
        let trashed = Set(records.filter { $0.trashed != nil || $0.collectionID.map(hidden.contains) == true }.compactMap { $0.remarkable?.id }).subtracting(active)
        return documents(folders, items: items).subtracting(trashed)
    }
}
