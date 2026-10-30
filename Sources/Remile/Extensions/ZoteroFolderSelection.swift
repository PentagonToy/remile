import Foundation

enum ZoteroFolderSelection {
    static func descendants(_ scope: ZoteroScope, collections: [ZoteroCollection]) throws -> [ZoteroScope] {
        guard let parent = scope.collection else { return [scope] }
        guard let current = collections.first(where: { $0.id == parent.id }) else {
            throw ReferenceFailure("A connected Zotero collection is unavailable. Existing references were kept.")
        }
        let children = Dictionary(grouping: collections, by: { $0.parent ?? "" })
        var pending = [current], seen = Set<String>(), scopes: [ZoteroScope] = []
        while let collection = pending.popLast() {
            guard seen.insert(collection.id).inserted else { continue }
            scopes.append(ZoteroScope(library: scope.library, collection: collection))
            pending.append(contentsOf: children[collection.id] ?? [])
        }
        return scopes
    }
    static func canonical(_ selected: Set<String>, scopes: [ZoteroScope]) -> Set<String> {
        let byID = Dictionary(scopes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.filter { id in
            guard let scope = byID[id], scope.collection != nil else { return true }
            if selected.contains(ZoteroScope(library: scope.library).id) { return false }
            var parent = scope.collection?.parent, seen: Set<String> = [id]
            while let key = parent, seen.insert(key).inserted {
                let id = scope.library.id + ":" + key
                if selected.contains(id) { return false }
                parent = byID[id]?.collection?.parent
            }
            return true
        }
    }
}
