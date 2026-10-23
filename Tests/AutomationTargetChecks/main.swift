import AppKit
import Foundation

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        let fixtures = output.appendingPathComponent("fixtures")
        let zip = try Data(contentsOf: fixtures.appendingPathComponent("source.zip"))
        let extracted = output.appendingPathComponent("extracted")
        let sources = try TeXSourceArchive.extract(zip, at: extracted)
        precondition(sources["main.tex"]?.contains("Free project") == true)
        let marker = try Data(contentsOf: extracted.appendingPathComponent("images/marker.bin"))
        precondition(marker == Data([0,1,2,255]))
        let unchanged = try Data(contentsOf: fixtures.appendingPathComponent("source.zip"))
        precondition(unchanged == zip, "Archive stays unchanged")
        for name in ["traversal", "git", "backslash", "absolute"] {
            let destination = output.appendingPathComponent("bad-" + name)
            do { _ = try TeXSourceArchive.extract(Data(contentsOf: fixtures.appendingPathComponent(name + ".zip")), at: destination); fatalError("Unsafe archive accepted") }
            catch { precondition(!fm.fileExists(atPath: destination.path)) }
        }
        do { _ = try TeXSourceArchive.extract(zip, at: extracted); fatalError("Existing destination replaced") } catch { }
        let broken = output.appendingPathComponent("broken")
        _ = try TeXSourceArchive.extract(Data(contentsOf: fixtures.appendingPathComponent("broken.zip")), at: broken)
        let unfinished = try TeXProject(broken, historyEnabled: false)
        precondition(unfinished.buffers["main.tex"]?.hasPrefix("documentclass") == true, "Broken source remains editable")
        let nested = output.appendingPathComponent("nested")
        _ = try TeXSourceArchive.extract(Data(contentsOf: fixtures.appendingPathComponent("nested.zip")), at: nested)
        let nestedRoot = try TeXSourceArchive.projectRoot(in: nested)
        precondition(nestedRoot.lastPathComponent == "Wrapped")
        if case .latex = try HomeFileDrop.plan([fixtures.appendingPathComponent("source.zip")], target: .latex) { } else { fatalError("ZIP drop not routed to LaTeX") }
        print("Passed source ZIP extraction, asset preservation, invalid-path rollback, broken source and drop routing checks")

        let other = output.appendingPathComponent("other")
        _ = try TeXSourceArchive.extract(zip, at: other)
        let a = HomeModel(index: LibraryIndex(location: output.appendingPathComponent("a.sqlite")), overleaf: OverleafLibrary(directory: output.appendingPathComponent("account-a")))
        let b = HomeModel(index: LibraryIndex(location: output.appendingPathComponent("b.sqlite")), overleaf: OverleafLibrary(directory: output.appendingPathComponent("account-b")))
        a.texProject = try TeXProject(extracted, historyEnabled: false)
        b.texProject = try TeXProject(other, historyEnabled: false)
        let wa = NSWindow(), wb = NSWindow()
        RemileWindows.shared.register(a, window: wa); RemileWindows.shared.register(b, window: wb)
        defer { RemileWindows.shared.remove(wa); RemileWindows.shared.remove(wb) }
        let mailbox = output.appendingPathComponent("mailbox")
        try fm.createDirectory(at: mailbox, withIntermediateDirectories: true)
        let service = Task { @MainActor in await EditorBridge.serve({ b }, directory: mailbox) }
        func call(_ request: EditorBridge.Request) async throws -> [String: Any] {
            try JSONEncoder().encode(request).write(to: mailbox.appendingPathComponent(request.id.uuidString + ".request.json"), options: .atomic)
            let reply = mailbox.appendingPathComponent(request.id.uuidString + ".response.json")
            let deadline = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: reply.path) {
                guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as! [String: Any]
        }
        let discovered = try await call(EditorBridge.Request(operation: "documents"))
        precondition((discovered["documents"] as? [[String: Any]])?.count == 2)
        let target = a.automationTarget!, before = a.texProject!.buffers["main.tex"]!
        var edit = EditorBridge.Request(operation: "replace", file: "main.tex")
        edit.target = target; edit.expectedSHA256 = EditorBridge.digest(before); edit.source = before + "% Target A only\n"
        let applied = try await call(edit)
        precondition(applied["ok"] as? Bool == true && a.texProject!.dirty && !b.texProject!.dirty, "An explicit target is independent of active window and identical source hashes")
        a.texProject = try TeXProject(extracted, historyEnabled: false)
        // Reuse a fresh request ID for a genuinely new stale-target attempt.
        var stale = edit; stale.id = UUID()
        let staleReply = try await call(stale)
        precondition(staleReply["ok"] as? Bool == false && !a.texProject!.dirty && !b.texProject!.dirty, "A reopened document rejects its old session identity")
        let active = try await call(EditorBridge.Request(operation: "status"))
        precondition(active["target"] as? String == b.automationTarget!.uuidString)
        service.cancel(); await service.value
        print("Passed document discovery, exact-target writes, active-window compatibility and stale-session rejection")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
RunLoop.main.run()
