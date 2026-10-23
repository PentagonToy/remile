import Foundation

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
func require(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
Task { @MainActor in
    do {
        let directory = output.appendingPathComponent("accounts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldID = UUID()
        let oldJSON = "[{\"id\":\"\(oldID.uuidString)\",\"name\":\"Legacy\"}]"
        try Data(oldJSON.utf8).write(to: directory.appendingPathComponent("accounts.json"))
        let library = OverleafLibrary(directory: directory)
        require(library.accounts.count == 1 && library.accounts[0].id == oldID && library.accounts[0].plan == nil && library.allowsGit(oldID), "Legacy accounts retain their identity and behaviour before plan selection")
        let free = library.saveAccount(name: "Free account", token: "", plan: .free)!
        let premium = library.saveAccount(name: "Premium account", token: "", plan: .premium)!
        library.setPlan(.free, premiumProjectAccess: false, for: oldID)
        require(!library.allowsGit(free.id) && !library.allowsGit(oldID) && library.allowsGit(premium.id), "Changing one account does not change another account's access")
        library.setPlan(.free, premiumProjectAccess: true, for: free.id)
        let reopened = OverleafLibrary(directory: directory)
        require(reopened.accounts.count == 3 && reopened.allowsGit(free.id) && !reopened.allowsGit(oldID) && reopened.allowsGit(premium.id), "Plan choices and Premium project access survive reopening")
        require(reopened.accounts.first { $0.id == free.id }?.plan == .free, "Premium project access does not relabel the Free account")
        reopened.setPlan(.free, premiumProjectAccess: false, for: free.id)
        require(reopened.saveAccount(name: "Free account", token: "")?.id == free.id && !reopened.allowsGit(free.id), "Saving account details preserves the selected plan and identity")
        var connection = OverleafConnection(id: UUID(), projectID: "1234567890abcdef12345678", name: "Fixture", account: free.name, branch: "master")
        connection.profileID = free.id
        var saves = 0
        await reopened.check(connection, save: { saves += 1; return false })
        require(saves == 0 && reopened.error == OverleafLibrary.premiumHint && !reopened.busy, "A restricted manual sync stops before saving or running Git")
        reopened.error = nil
        await reopened.syncLocalChanges(connection, save: { saves += 1; return false })
        require(saves == 0 && reopened.error == nil && !reopened.busy, "Restricted automatic sync is quiet and performs no work")
        reopened.setPlan(.premium, premiumProjectAccess: false, for: free.id)
        let upgraded = OverleafLibrary(directory: directory)
        require(upgraded.allowsGit(free.id) && upgraded.accounts.first { $0.id == free.id }?.plan == .premium, "An upgraded plan restores eligibility without replacing the account")
        let second = OverleafConnection(id: UUID(), projectID: connection.projectID, name: "Other account", account: premium.name, branch: "master")
        var other = second; other.profileID = premium.id
        try JSONEncoder().encode([connection, other]).write(to: directory.appendingPathComponent("projects.json"))
        let tagLibrary = OverleafLibrary(directory: directory)
        let red = OverleafWebClient.Tag(id: "red", name: "Repository", color: "#f94144")
        tagLibrary.rememberTags([.init(id: connection.projectID, name: connection.name, tags: [red])], profile: free.id)
        tagLibrary.rememberTags([.init(id: connection.projectID, name: connection.name, tagsLoaded: false)], profile: free.id)
        require(tagLibrary.tags[connection.id] == [red] && tagLibrary.unavailableTags.contains(connection.id), "Unavailable tag metadata preserves saved colours and marks the refresh failure")
        require(tagLibrary.tags[other.id] == nil, "Tag updates never cross account boundaries even for the same project")
        tagLibrary.rememberTags([.init(id: connection.projectID, name: connection.name)], profile: free.id)
        require(tagLibrary.tags[connection.id] == [] && !tagLibrary.unavailableTags.contains(connection.id), "A confirmed empty tag response clears removed tags")
        let parsed = try OverleafWebClient.parseProjects(Data("{\"projects\":[{\"_id\":\"1234567890abcdef12345678\",\"name\":\"Fixture\"}]}".utf8))
        require(parsed.count == 1 && !parsed[0].tagsLoaded, "Project listings do not imply that tag metadata was loaded")
        do { _ = try OverleafWebClient.parseTags(Data("[{\"name\":\"broken\"}]".utf8)); fatalError("Malformed tags accepted") }
        catch OverleafWebClient.Failure.response { print("PASS: Malformed tag data cannot replace saved tags with an empty list") }
        print("Passed account plan persistence and Git restrictions. No credentials or server requests used.")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
RunLoop.main.run()
