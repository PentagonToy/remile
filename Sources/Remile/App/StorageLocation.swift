import Foundation

enum StorageLocation {
    static let preference = "storage.dataDirectory"
    static let pendingPreference = "storage.pendingDataDirectory"
    static let machinePreference = "storage.searchMachine"
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app") }
    static func root(defaults: UserDefaults = .standard) -> URL {
        defaults.string(forKey: preference).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? support
    }
    static func requireAvailable(defaults: UserDefaults = .standard) throws {
        guard defaults.string(forKey: preference) != nil else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root(defaults: defaults).path, isDirectory: &directory), directory.boolValue,
              FileManager.default.fileExists(atPath: root(defaults: defaults).appendingPathComponent("remile-storage.json").path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Reconnect the drive containing your remile storage."])
        }
    }
    static func search(defaults: UserDefaults = .standard) -> URL {
        guard defaults.string(forKey: preference) != nil else { return support.appendingPathComponent("Search/library-v1.sqlite") }
        var machine = defaults.string(forKey: machinePreference).flatMap(UUID.init(uuidString:))?.uuidString
        if machine == nil { machine = UUID().uuidString; defaults.set(machine!, forKey: machinePreference) }
        return root(defaults: defaults).appendingPathComponent("Search/" + machine! + "/library-v1.sqlite")
    }
}
