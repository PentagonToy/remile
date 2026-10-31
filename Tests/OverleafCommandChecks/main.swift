import Foundation

// Keep account credentials, network services and real preferences outside these checks.
struct OverleafConnection {
    let id: UUID
    let projectID: String
    let name: String
    var webURL: URL { URL(string: "https://www.overleaf.com/project/" + projectID)! }
}
@MainActor final class OverleafLibrary {
    let directory: URL
    var projects: [OverleafConnection] = []
    var browsing = true
    var syncedAt: [UUID: Date] = [:]
    var statuses: [UUID: String] = [:]
    init(_ directory: URL) { self.directory = directory }
    func root(_ project: OverleafConnection) -> URL { directory.appendingPathComponent(project.id.uuidString) }
}
@MainActor final class TestLiveWorkspace {
    var automationStatus: [String: Any] = ["transport": "git", "mode": "online", "enabled": true, "connected": true, "confirmed": false, "pendingDocuments": 1]
}
@MainActor final class TestProject {
    let liveWorkspace = TestLiveWorkspace()
    let identity = UUID()
    let root: URL
    var buffers: [String: String] = ["main.tex": "unsaved source"]
    var dirty = true
    let main = "main.tex"
    let compiling = false
    var pdf: String? = "old PDF"
    let outputCurrent = false
    var sourceHashes: [String: String] { buffers.mapValues(SourceDigest.sha256) }
    init(_ root: URL) { self.root = root }
}
@MainActor final class HomeModel {
    enum Page { case home, writer }
    struct Reader { var dirty = false }
    struct Writer { var dirty = false }
    let overleaf: OverleafLibrary
    var texProject: TestProject?
    var page = Page.home
    var reader = Reader()
    var writer: Writer?
    var opening = false
    var error: String?
    var opens = 0
    var automationTarget: UUID? { texProject?.identity }
    init(_ library: OverleafLibrary) { overleaf = library }
    func open(_ root: URL) { opens += 1; texProject = TestProject(root) }
}
enum EditorBridge {
    struct Request {
        var action: String?
        var source: String?
        var name: String?
        var kind: String?
        var file: String?
        var target: UUID?
        var output: String?
    }
}

@MainActor enum OverleafReviewCommands {
    static func handle(connection: OverleafConnection, root: URL, project: TestProject?, format: String?, output: String?, library: OverleafLibrary) async -> [String: Any] {
        ["ok": true, "review": true, "projectID": connection.projectID, "format": format ?? "json", "opened": project != nil]
    }
}

Task { @MainActor in
    do {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = OverleafLibrary(parent), home = HomeModel(library)
        let id = "0123456789abcdef01234567"
        let project = OverleafConnection(id: UUID(), projectID: id, name: "Renamed paper")
        library.projects = [project]
        let review = await OverleafCommands.handle(.init(action: "review", source: "overleaf:" + id, kind: "json"), homes: [home], current: home)
        precondition(review["ok"] as? Bool == true && review["review"] as? Bool == true && review["opened"] as? Bool == false && home.opens == 0)
        let root = library.root(project)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "saved source".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        func request(_ action: String, file: String? = nil, target: UUID? = nil, connection: UUID? = nil) -> EditorBridge.Request {
            EditorBridge.Request(action: action, source: "overleaf:" + id, name: connection?.uuidString, file: file, target: target)
        }
        func call(_ request: EditorBridge.Request, homes: [HomeModel]? = nil) async -> [String: Any] { await OverleafCommands.handle(request, homes: homes ?? [home], current: home) }
        let closed = await call(request("show"))
        precondition(closed["live"] is NSNull)
        precondition(closed["online"] is NSNull)
        precondition(closed["ok"] as? Bool == true && closed["pdfCurrent"] is NSNull && home.opens == 0)
        let disk = await call(request("read", file: "main.tex"))
        precondition(disk["source"] as? String == "saved source" && disk["origin"] as? String == "disk")
        precondition(disk["sha256"] as? String == SourceDigest.sha256("saved source"))
        let traversal = await call(request("read", file: "../main.tex"))
        precondition(traversal["ok"] as? Bool == false)
        let outside = parent.appendingPathComponent("outside.tex")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.tex"), withDestinationURL: outside)
        let escape = await call(request("read", file: "escape.tex"))
        precondition(escape["ok"] as? Bool == false)
        home.reader.dirty = true
        let blocked = await call(request("open"))
        precondition(blocked["ok"] as? Bool == false && home.opens == 0)
        home.reader.dirty = false
        let opened = await call(request("open"))
        precondition(opened["ok"] as? Bool == true && home.opens == 1 && !library.browsing)
        let buffer = await call(request("read", file: "main.tex"))
        precondition(buffer["source"] as? String == "unsaved source" && buffer["origin"] as? String == "editor-buffer")
        precondition(buffer["dirty"] as? Bool == true && buffer["pdfCurrent"] as? Bool == false)
        precondition((buffer["live"] as? [String: Any])?["pendingDocuments"] as? Int == 1)
        precondition((buffer["live"] as? [String: Any])?["confirmed"] as? Bool == false)
        let online = buffer["online"] as? [String: Any]
        precondition(online?["transport"] as? String == "git" && online?["mode"] as? String == "online")
        let onlineJSON = try JSONSerialization.data(withJSONObject: buffer["online"]!, options: .sortedKeys)
        let legacyJSON = try JSONSerialization.data(withJSONObject: buffer["live"]!, options: .sortedKeys)
        precondition(onlineJSON == legacyJSON)
        let again = await call(request("open"))
        precondition(again["ok"] as? Bool == true && home.opens == 1)
        let second = HomeModel(library); second.texProject = TestProject(root)
        let ambiguous = await call(request("show"), homes: [home, second])
        precondition(ambiguous["ok"] as? Bool == false)
        let exact = await call(request("show", target: second.automationTarget), homes: [home, second])
        precondition(exact["target"] as? String == second.automationTarget?.uuidString)
        let wrong = await call(request("show", target: UUID()))
        precondition(wrong["ok"] as? Bool == false)
        library.projects.append(OverleafConnection(id: UUID(), projectID: id, name: "Second account"))
        let duplicate = await call(request("show"))
        precondition(duplicate["ok"] as? Bool == false)
        let account = await call(request("show", connection: project.id))
        precondition(account["ok"] as? Bool == true)
        precondition(account["remoteFreshness"] as? String == "not-checked")
        _ = try JSONSerialization.data(withJSONObject: account)
        print("Passed Overleaf routing, disk/buffer provenance, stale PDF, duplicate connection/window, unsaved-work and path-boundary checks.")
        exit(0)
    } catch { print(error); exit(1) }
}
dispatchMain()
