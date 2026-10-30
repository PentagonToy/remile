import Foundation
import CryptoKit

/// Connected citation metadata only. No Reference catalogue or PDF copies.
actor ZoteroCitationSources {
    static let shared = ZoteroCitationSources()
    static let preference = "extensions.zotero.citationScopes"
    static let revisionKey = "extensions.zotero.citationRevision"
    private var cached: (String, [ReferenceRecord])?
    private let client = ZoteroLocalClient()
    nonisolated static var scopes: [ZoteroScope] {
        guard let data = UserDefaults.standard.data(forKey: preference) else { return [] }
        return (try? JSONDecoder().decode([ZoteroScope].self, from: data)) ?? []
    }
    nonisolated static var signature: String {
        String(UserDefaults.standard.bool(forKey: ZoteroAccess.enabledKey)) + (UserDefaults.standard.string(forKey: revisionKey) ?? "")
    }
    nonisolated static func identity(_ text: String) -> UUID {
        let hex = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let lengths = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        let parts = lengths.map { length -> String in
            let end = hex.index(index, offsetBy: length); defer { index = end }
            return String(hex[index..<end])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
    nonisolated static var libraries: [ReferenceLibrary] {
        guard UserDefaults.standard.bool(forKey: ZoteroAccess.enabledKey) else { return [] }
        return scopes.map { scope in
            ReferenceLibrary(id: identity(scope.id), name: "Zotero · " + (scope.collection?.name ?? scope.library.name), source: "zotero:" + scope.id)
        }
    }
    nonisolated static func citationRecord(_ item: ZoteroItem, scope: ZoteroScope) throws -> ReferenceRecord {
        var record = try item.reference(in: scope.library)
        let source = record.fields["zoterosource"]!
        record.id = identity(scope.id + ":" + item.key)
        record.libraryID = identity(scope.id)
        record.key = "zt" + identity(scope.library.id).uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() + "_" + item.key
        record.fields["zoterosource"] = source
        record.fields["zoterolibrary"] = scope.library.name
        if let collection = scope.collection { record.fields["zoterocollection"] = collection.name }
        return record
    }
    nonisolated static func origin(_ record: ReferenceRecord) -> String? {
        guard record.fields["zoterosource"]?.isEmpty == false else { return nil }
        let library = record.fields["zoterolibrary"] ?? "Connected source"
        if let collection = record.fields["zoterocollection"] { return "Zotero · " + library + " / " + collection }
        return "Zotero · " + library
    }
    private func read(_ scopes: [ZoteroScope]) async throws -> [ReferenceRecord] {
        var result: [ReferenceRecord] = []
        for scope in scopes {
            let children: [ZoteroScope]
            if scope.collection != nil { children = try ZoteroFolderSelection.descendants(scope, collections: await client.collections(scope.library)) }
            else { children = [scope] }
            var seen = Set<String>(), version: String?
            for childScope in children {
                var done = false
                for start in stride(from: 0, to: 10000, by: 100) {
                    try Task.checkCancellation(); try ZoteroAccess.requireEnabled()
                    let (items, nextVersion) = try await client.items(childScope, start: start)
                    if let version, let nextVersion, version != nextVersion { throw ReferenceFailure("Zotero changed. Refresh the connection and try again.") }
                    version = nextVersion
                    for item in items where item.isReference && seen.insert(item.key).inserted {
                        var record = try Self.citationRecord(item, scope: scope)
                        if let collection = childScope.collection { record.fields["zoterocollection"] = collection.name }
                        result.append(record)
                        guard result.count <= 10000 else { throw ReferenceFailure("Connect fewer than 10,000 Zotero references.") }
                    }
                    if items.count < 100 { done = true; break }
                }
                guard done else { throw ReferenceFailure("Choose a smaller Zotero library or collection.") }
            }
        }
        return result
    }
    func connect(_ scopes: [ZoteroScope]) async throws {
        let records = try await read(scopes)
        try Task.checkCancellation(); try ZoteroAccess.requireEnabled()
        UserDefaults.standard.set(try JSONEncoder().encode(scopes), forKey: Self.preference)
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.revisionKey)
        cached = (Self.signature, records)
    }
    func clear() { cached = nil }
    func records() async throws -> [ReferenceRecord] {
        guard UserDefaults.standard.bool(forKey: ZoteroAccess.enabledKey) else { cached = nil; return [] }
        let signature = Self.signature
        if let cached, cached.0 == signature { return cached.1 }
        let result = try await read(Self.scopes)
        guard signature == Self.signature else { throw CancellationError() }
        cached = (signature, result)
        return result
    }
}
