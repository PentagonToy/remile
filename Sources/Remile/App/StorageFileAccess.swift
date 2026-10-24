import Foundation

enum StorageFileAccess {
    static let readOnlyPreference = "storage.readOnlyReference"
    static func requireWritable(_ file: URL, defaults: UserDefaults = .standard) throws {
        guard let path = defaults.string(forKey: readOnlyPreference), path.hasPrefix("/") else { return }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let destination = file.resolvingSymlinksInPath().standardizedFileURL.path
        if destination == root || destination.hasPrefix(root + "/") {
            throw NSError(domain: "Remile", code: 1, userInfo: [NSLocalizedDescriptionKey: "This library is read only. Save a copy outside the library."])
        }
    }
}
