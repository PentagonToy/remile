import AppKit
import SwiftUI
import WebKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func require(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
@MainActor func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        precondition(ContinuousClock.now < deadline, "Timed out waiting for connection state")
        try await Task.sleep(for: .milliseconds(20))
    }
}
Task { @MainActor in
    do {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = original; overrides[NetworkAccessGate.preference] = true
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        func response(_ status: Int, _ mime: String = "application/json", location: String? = nil) -> HTTPURLResponse {
            var headers = ["Content-Type": mime]; headers["Location"] = location
            return HTTPURLResponse(url: URL(string: "https://www.overleaf.com/user/projects")!, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        for (status, expected) in [(401, OverleafWebClient.Failure.signIn), (403, .permission), (429, .rateLimited), (500, .unavailable), (503, .unavailable), (404, .response)] {
            require(OverleafWebClient.responseFailure(response(status)) == expected, "HTTP \(status) gives the correct recovery action")
        }
        require(OverleafWebClient.responseFailure(response(403, "text/html")) == .verification, "Browser verification differs from JSON access denial")
        for failure in [OverleafWebClient.Failure.response, .permission, .rateLimited, .unavailable] {
            require(!failure.needsConnection, "Recoverable or permission errors do not request another login: \(failure)")
        }
        require(OverleafWebClient.Failure.signIn.needsConnection && OverleafWebClient.Failure.verification.needsConnection, "Expired sessions and verification expose the same connection action")
        require(OverleafWebClient.Failure.sessionLocked.needsConnection, "Denied saved-session access exposes an actionable connection screen")
        let access = OverleafSessionAccess(), profile = UUID(), now = Date(timeIntervalSince1970: 1_000)
        var silentReads = 0
        for _ in 0..<3 {
            do { try await access.restore(profile, now: now) { silentReads += 1; throw OverleafWebClient.Failure.sessionLocked }; fatalError("Denied restore accepted") }
            catch OverleafWebClient.Failure.sessionLocked { }
        }
        require(silentReads == 1, "Repeated denied silent requests share a thirty-second backoff")
        try await access.restore(UUID(), now: now) { silentReads += 1 }
        require(silentReads == 2, "One account's denial never blocks another account")
        try await access.restore(profile, now: now.addingTimeInterval(31)) { silentReads += 1 }
        require(silentReads == 3, "Silent access retries after the bounded backoff")
        do { try await access.restore(profile, now: now.addingTimeInterval(32)) { throw OverleafWebClient.Failure.sessionLocked } } catch { }
        var approvals = 0
        try await access.restore(profile, interactive: true, now: now.addingTimeInterval(32)) { approvals += 1 }
        require(approvals == 1, "Explicit approval bypasses the silent-read backoff")
        var resumeRestore: CheckedContinuation<Void, Error>?, sharedReads = 0
        let sharedProfile = UUID()
        let firstRestore = Task { try await access.restore(sharedProfile) {
            sharedReads += 1
            try await withCheckedThrowingContinuation { resumeRestore = $0 }
        } }
        try await until { resumeRestore != nil }
        var secondStarted = false
        let secondRestore = Task { secondStarted = true; try await access.restore(sharedProfile) { sharedReads += 1 } }
        try await until { secondStarted }
        resumeRestore!.resume(); try await firstRestore.value; try await secondRestore.value
        require(sharedReads == 1, "Concurrent requests use one account restore instead of repeating Keychain access")
        require(OverleafWebClient.responseFailure(response(302, location: "/login?next=%2Fproject")) == .signIn, "Only a login redirect asks for authentication")
        require(OverleafWebClient.responseFailure(response(302, location: "https://example.com/login")) == .response, "Unrelated redirects do not masquerade as expired sessions")
        require(OverleafWebClient.responseFailure(response(200, "text/html")) == .response, "Unexpected HTML is not labelled a successful login")
        require(OverleafWebClient.responseFailure(response(200, "application/json; charset=utf-8")) == nil, "JSON with charset is accepted")
        let empty = try OverleafWebClient.parseProjects(Data(#"{"projects":[]}"#.utf8))
        require(empty.isEmpty, "An authenticated account with no projects is valid")
        do { _ = try OverleafWebClient.parseProjects(Data(#"{"login":true}"#.utf8)); fatalError("Malformed project list accepted") } catch { }
        func cookie(_ domain: String, expiry: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name:"overleaf_session2", .value:"fixture", .domain:domain, .path:"/"]
            if let expiry { properties[.expires] = expiry }
            return HTTPCookie(properties: properties)!
        }
        require(OverleafWebIdentity.isUsable(cookie(".overleaf.com")), "Own session cookies can be restored")
        require(!OverleafWebIdentity.isUsable(cookie("other.overleaf.com")) && !OverleafWebIdentity.isUsable(cookie("overleaf.com.evil.example")), "Session restore excludes unrelated domains")
        require(!OverleafWebIdentity.isUsable(cookie("overleaf.com", expiry: Date(timeIntervalSince1970: 1))), "Expired cookies cannot suppress restoration")
        require(HelpBubbleStyle.standard.schemaVersion == 1 && HelpBubbleStyle.standard.width == 320, "Native help loads the reusable template")
        for dark in [false, true] {
            for kind in ["icon", "banner", "wordmark", "lighthouse", "airplane"] {
                require(RemileArtwork.image(kind, dark: dark) != nil, "Categorised artwork resolves: \(kind) \(dark ? "dark" : "light")")
            }
        }
        let directory = output.appendingPathComponent("accounts")
        let library = OverleafLibrary(directory: directory)
        let account = library.saveAccount(name: "  Personal  ", token: "")!
        require(library.accounts.count == 1 && account.name == "Personal", "Browsing account setup does not require a Git token")
        require(library.saveAccount(name: "Personal", token: "")?.id == account.id, "Saving an existing account preserves its session identity")
        require(library.saveAccount(name: "  ", token: "") == nil, "Blank account labels are rejected")
        let reopened = OverleafLibrary(directory: directory)
        require(reopened.accounts == library.accounts, "Existing account format survives a reopen without migration")
        reopened.openLibrary()
        require(reopened.browsing && !reopened.presented && !reopened.adding, "Home opens the saved-project library directly")
        reopened.openLibrary(add: true)
        require(reopened.presented && reopened.adding, "Add projects remains available from the library")
        await library.connect(url: "https://www.overleaf.com/project/6ad72e207e5cd74f01fe6b18", name: "Fixture", account: account.name, token: "")
        require(library.projects.isEmpty && library.error?.contains("Git token") == true && !library.busy, "Missing Git token cannot start a clone or leave a partial project")
        do { _ = try await OverleafWebClient.request("/user/projects", profile: UUID()); fatalError("Offline request accepted") } catch is NetworkAccessGate.Offline { }
        let signIn = OverleafSignInSession(profile: UUID())
        try await until { !signIn.checking }
        require(!signIn.signedIn && !signIn.checking && signIn.issue != nil, "Offline session verification stops with a retryable issue")
        signIn.stop()
        let validProjects = Data(#"{"projects":[]}"#.utf8)
        var fetches = 0, saves = 0
        let reused = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in fetches += 1; return validProjects }, saveSession: { _ in saves += 1; return true })
        try await until { reused.signedIn }
        require(reused.signedIn && fetches == 1 && saves == 1 && reused.web.url == nil, "A valid saved session completes without opening the login page")
        reused.stop()
        let malformed = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in Data(#"{"login":true}"#.utf8) }, saveSession: { _ in fatalError("Invalid session persisted") })
        try await until { !malformed.checking }
        require(!malformed.signedIn && malformed.issue != nil, "A malformed project response never marks the account connected")
        malformed.stop()
        let unavailable = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in throw OverleafWebClient.Failure.unavailable }, saveSession: { _ in false })
        try await until { !unavailable.checking }
        require(!unavailable.signedIn && unavailable.issue == OverleafWebClient.Failure.unavailable.localizedDescription && unavailable.web.url == nil, "Server failure offers retry without opening login")
        unavailable.stop()
        var unlocked = false, unlockCalls = 0
        let lockedSession = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in
            guard unlocked else { throw OverleafWebClient.Failure.sessionLocked }; return validProjects
        }, saveSession: { _ in true }, unlockSession: { _ in unlockCalls += 1; unlocked = true })
        try await until { !lockedSession.checking }
        require(lockedSession.needsSessionAccess && lockedSession.web.url == nil && unlockCalls == 0, "Denied access neither prompts automatically nor reopens login")
        lockedSession.verifySession(allowSavedSession: true)
        try await until { lockedSession.signedIn }
        require(unlockCalls == 1 && !lockedSession.needsSessionAccess, "One explicit saved-session action restores and verifies the account")
        lockedSession.stop()
        let deniedSession = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in throw OverleafWebClient.Failure.sessionLocked }, saveSession: { _ in false }, unlockSession: { _ in throw OverleafWebClient.Failure.sessionLocked })
        try await until { !deniedSession.checking }; deniedSession.verifySession(allowSavedSession: true)
        try await until { !deniedSession.checking }
        require(!deniedSession.signedIn && deniedSession.needsSessionAccess && deniedSession.web.url == nil, "Declining access leaves a recoverable screen without a prompt or login loop")
        deniedSession.stop()
        let rejectedLogin = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in throw OverleafWebClient.Failure.signIn }, saveSession: { _ in false })
        rejectedLogin.verifySession(afterLogin: true)
        try await until { !rejectedLogin.checking }
        require(!rejectedLogin.signedIn && rejectedLogin.issue == OverleafWebClient.Failure.signIn.localizedDescription && rejectedLogin.web.url == nil, "A rejected post-login check does not reopen login in a loop")
        rejectedLogin.stop()
        let unsaved = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in validProjects }, saveSession: { _ in false })
        try await until { !unsaved.checking }
        require(!unsaved.signedIn && unsaved.storageWarning != nil, "Keychain save failure is visible before continuing")
        unsaved.continueWithoutSaving(); require(unsaved.signedIn, "A connected session remains usable when saving is unavailable"); unsaved.stop()
        var fetchStarted = false, fetchCancelled = false
        let cancelled = OverleafSignInSession(profile: UUID(), fetchProjects: { _ in
            fetchStarted = true
            do { try await Task.sleep(for: .seconds(30)); return validProjects }
            catch { fetchCancelled = true; throw error }
        }, saveSession: { _ in fatalError("Cancelled session persisted") })
        try await until { fetchStarted }; cancelled.stop(); try await until { fetchCancelled }
        require(!cancelled.signedIn && !cancelled.checking, "Closing connection cancels verification before saving or completing")
        try await checkLiveWorkspace(output: output, check: require)
        let brandedDirectory = output.appendingPathComponent("brand-library")
        try FileManager.default.createDirectory(at: brandedDirectory, withIntermediateDirectories: true)
        let fixtureConnection = OverleafConnection(id: UUID(), profileID: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Fixture manuscript", account: "Fixture", branch: "master")
        try JSONEncoder().encode([fixtureConnection]).write(to: brandedDirectory.appendingPathComponent("projects.json"))
        let brandedLibrary = OverleafLibrary(directory: brandedDirectory)
        require(brandedLibrary.title(for: brandedLibrary.root(fixtureConnection)) == "Overleaf", "Project title leaves connection status to the sync toolbar")
        require(brandedLibrary.title(for: output.appendingPathComponent("local-tex")) == "LaTeX", "Unlinked local projects retain their LaTeX title")
        let sidebarRoot = output.appendingPathComponent("collapsed-sidebar")
        try FileManager.default.createDirectory(at: sidebarRoot, withIntermediateDirectories: true)
        try "\\documentclass{article}\n\\begin{document}\nFixture\n\\end{document}".write(to: sidebarRoot.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let sidebarProject = try TeXProject(sidebarRoot, historyEnabled: false), sidebarState = TeXSidebarState()
        sidebarState.files = false; sidebarState.outline = false
        // Render the actual connection screen offline; no login, cookie or remote-project access.
        for dark in [true, false] {
            let host = NSHostingView(rootView: OverleafProjects(library: reopened, open: {_ in}, prepareRemoval: {_ in true}).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 868,height: 610),styleMask:[.titled],backing:.buffered,defer:false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "connection-dark.png" : "connection-light.png"))
            }
            window.orderOut(nil)
            for (name, view, size) in [
                ("overleaf-library", AnyView(OverleafLibraryWorkspace(library: brandedLibrary, open: {_ in}, prepareRemoval: {_ in false})), NSSize(width: 950, height: 700)),
                ("live-review", AnyView(OverleafLiveReview(conflict: .init(path: "main.tex", local: "Local introduction\n\nUnchanged paragraph\n\nLocal conclusion\n", remote: .init(version: 2, text: "Overleaf introduction\n\nUnchanged paragraph\n\nOverleaf conclusion\n")), choose: {_ in}, close: {})), NSSize(width: 900, height: 580)),
                ("overleaf-status", AnyView(OverleafBar(library: brandedLibrary, project: sidebarProject, connection: fixtureConnection)), NSSize(width: 1100, height: 48)),
                ("overleaf-status-narrow", AnyView(OverleafBar(library: brandedLibrary, project: sidebarProject, connection: fixtureConnection)), NSSize(width: 600, height: 48)),
                ("overleaf-status-wide", AnyView(OverleafBar(library: brandedLibrary, project: sidebarProject, connection: fixtureConnection)), NSSize(width: 1400, height: 48)),
                ("sync-mode-live", AnyView(OverleafSyncModePicker(isLive: true, canStart: true, switching: false, choose: {_ in})), NSSize(width: 168, height: 48)),
                ("collapsed-sidebar", AnyView(TeXProjectSidebar(project: sidebarProject, state: sidebarState)), NSSize(width: 240, height: 650))
            ] {
                let fixture = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
                let fixtureWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                fixtureWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                fixtureWindow.contentView = fixture; fixtureWindow.orderFront(nil)
                await Task.yield(); fixture.layoutSubtreeIfNeeded()
                require(fixture.fittingSize.height <= size.height + 1, "\(name) stays within its window height")
                if name.hasPrefix("overleaf-status") { require(fixture.fittingSize.width <= size.width + 1, "\(name) keeps every control within its window width") }
                if let bitmap = fixture.bitmapImageRepForCachingDisplay(in: fixture.bounds) {
                    fixture.cacheDisplay(in: fixture.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
                fixtureWindow.orderOut(nil)
            }
            let bubble = NSHostingView(rootView: HelpBubbleContent(text: RemileHints.overleafToken).environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink))
            bubble.frame = CGRect(origin: .zero, size: bubble.fittingSize); bubble.layoutSubtreeIfNeeded()
            if let bitmap = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) {
                bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "token-help-dark.png" : "token-help-light.png"))
            }
        }
        print("Passed Overleaf connection policy, account persistence, offline cancellation and native screen rendering")
        exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
