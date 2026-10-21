import AppKit
import CoreText
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func require(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS: " + message) }
func pdf(_ pages: [String]) -> Data {
    let bytes = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let graphics = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
    for text in pages {
        graphics.beginPDFPage(nil); graphics.textPosition = CGPoint(x: 40, y: 730)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])), graphics)
        graphics.endPDFPage()
    }
    graphics.closePDF(); return bytes as Data
}
@MainActor func raster(_ view: NSView, name: String) {
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
}
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let isolated = UserDefaults(suiteName: "remile.ai-checks." + UUID().uuidString)!
        let gate = NetworkAccessGate(defaults: isolated)
        var cancelled = 0
        let released = try gate.watch { cancelled += 100 }; gate.release(released)
        _ = try gate.watch { cancelled += 1 }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        let lease = try gate.start(process)
        gate.setOffline(true); process.waitUntilExit(); gate.release(lease)
        require(cancelled == 1 && process.terminationStatus != 0, "Offline cancels active work and leaves released work alone")
        do { _ = try gate.watch { }; fatalError("Offline accepted network operation") } catch is NetworkAccessGate.Offline { }
        let blocked = Process(); blocked.executableURL = URL(fileURLWithPath: "/bin/sleep"); blocked.arguments = ["30"]
        do { _ = try gate.start(blocked); fatalError("Offline started network process") } catch is NetworkAccessGate.Offline { }
        require(!blocked.isRunning, "Offline rejects new network work before starting it")
        gate.setOffline(false); try gate.requireOnline()
        require(!gate.offline, "Online services can resume without altering provider preferences")
        require(AIConfiguration.route(mode: .manual, gptReady: true, deviceReady: true, fallback: true) == .off, "Manual keeps AI off even when both providers are available")
        require(AIConfiguration.route(mode: .gpt, gptReady: false, deviceReady: true, fallback: false) == .unavailable, "GPT-only refuses automatic device inference")
        require(AIConfiguration.route(mode: .gpt, gptReady: false, deviceReady: true, fallback: true) == .device, "Opt-in fallback keeps unavailable GPT requests local")
        require(AIConfiguration.route(mode: .gpt, gptReady: true, deviceReady: false, fallback: true) == .gpt, "GPT remains usable on a Mac without Apple Intelligence")
        require(AIConfiguration.route(mode: .gpt, gptReady: false, deviceReady: false, fallback: true) == .unavailable, "Unavailable Apple Intelligence is never presented as usable fallback")
        let folder = output.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = LibraryIndex(location: output.appendingPathComponent("library.sqlite"))
        let bookPath = folder.appendingPathComponent("Book.pdf")
        let pages = (1...104).map { page in page == 103 ? "Linear system of equations Ax = b. Matrix A is known." : "Chapter \(page). General background." }
        let book = pdf(pages); try book.write(to: bookPath)
        let other = folder.appendingPathComponent("Other.pdf"); try pdf(["Linear system of equations, unrelated book."]).write(to: other)
        try await index.add(folder); try await index.refresh { _ in }
        let hits = try await index.assistantPages(path: bookPath.path, terms: ["linear", "equations"])
        require(hits == [103], "FTS candidates are restricted to the exact open book")
        let context = PDFAssistantContext(index: index)
        let selected = try await context.passages(data: book, password: "", path: bookPath.path, question: "What is a linear system of equations?", currentPage: 2, selection: nil, expanded: true) { _ in }
        require(selected.first?.location.unit == 103 && Set(selected.map(\.location.unit)).isSuperset(of: [102, 104]), "Indexed book retrieval includes relevant and adjacent pages")
        require(selected.count < 10 && selected.allSatisfy { $0.location.path == bookPath.path }, "Indexed retrieval stays small and scoped")
        let short = pdf((1...24).map { "Page \($0). Unique section \($0)." })
        let whole = try await context.passages(data: short, password: "", path: "/Short.pdf", question: "section 24", currentPage: 1, selection: nil, expanded: true) { _ in }
        let evidence = AssistantEvidence.make(whole, expanded: true)
        require(evidence.count == 24 && evidence.last?.text.contains("Unique section 24") == true, "Short papers preserve every extracted page through the final prompt budget")
        require(AssistantEvidence.citations(in: "Sections [13–24].", sources: evidence)?.count == 12, "Citations beyond the former twelve-page cap resolve correctly")
        let local = try await context.passages(data: short, password: "", path: "/Short.pdf", question: "section 24", currentPage: 24, selection: nil) { _ in }
        require(AssistantEvidence.make(local).reduce(0) { $0 + $1.text.utf8.count } <= 2600, "On-device evidence keeps its smaller bound")
        var revised = pages; revised[102] = "Background replaced."; revised[76] = "Linear equations moved to this section."
        let changed = pdf(revised); try changed.write(to: bookPath)
        require(try await index.assistantPages(path: bookPath.path, terms: ["linear"]) == nil, "A stale index is rejected")
        let fresh = try await context.passages(data: changed, password: "", path: bookPath.path, question: "linear equations", currentPage: 2, selection: nil, expanded: true) { _ in }
        require(fresh.first?.location.unit == 77, "Changed books fall back to current PDF text")
        // Volatile overrides affect only this test process, never the user's saved settings.
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for mode in AIConfiguration.Mode.allCases {
            var overrides = originalArguments
            overrides["chatgpt.limit100Default"] = true
            overrides["assistant.provider"] = mode.rawValue; overrides[NetworkAccessGate.preference] = true; overrides[AIConfiguration.fallbackPreference] = false
            UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
            require(AssistantEngine.selected.status().ready == (mode == .device && AppleIntelligence.status().ready), "Actual engine respects offline and GPT-only selection: \(mode.label)")
            let defaults = UserDefaults(suiteName: "remile.ui-checks." + UUID().uuidString)!
            defaults.set(mode.rawValue, forKey: "assistant.provider")
            let host = NSHostingView(rootView: Form { Section("AI assistance") { ChatGPTSettings(showsHeading: false, refreshModelsOnAppear: false) } }.formStyle(.grouped).scrollContentBackground(.hidden).defaultAppStorage(defaults).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); raster(host, name: "ai-" + mode.rawValue.replacingOccurrences(of: " ", with: "-")); window.orderOut(nil)
        }
        var searchOverrides = originalArguments
        searchOverrides[SearchBoostPolicy.preference] = true
        searchOverrides["assistant.provider"] = AIConfiguration.Mode.device.rawValue
        searchOverrides[NetworkAccessGate.preference] = true
        UserDefaults.standard.setVolatileDomain(searchOverrides, forName: UserDefaults.argumentDomain)
        let home = HomeModel(index: index)
        let question = "What is a linear system of equations?"
        let base = try await index.rankedSearch(question)
        let offlineSearch = try await home.librarySearch(question)
        require(offlineSearch.phrases.isEmpty && offlineSearch.hits.map(\.id) == base.map(\.id), "Actual search pipeline uses only B0 in offline mode")
        searchOverrides[NetworkAccessGate.preference] = false
        searchOverrides["assistant.provider"] = AIConfiguration.Mode.manual.rawValue
        UserDefaults.standard.setVolatileDomain(searchOverrides, forName: UserDefaults.argumentDomain)
        let manualSearch = try await home.librarySearch(question)
        require(manualSearch.phrases.isEmpty && manualSearch.hits.map(\.id) == base.map(\.id), "Actual search pipeline keeps Manual mode free of inference")
        searchOverrides["assistant.provider"] = AIConfiguration.Mode.device.rawValue
        searchOverrides[SearchBoostPolicy.preference] = false
        UserDefaults.standard.setVolatileDomain(searchOverrides, forName: UserDefaults.argumentDomain)
        let disabledSearch = try await home.librarySearch(question)
        require(disabledSearch.phrases.isEmpty && disabledSearch.hits.map(\.id) == base.map(\.id), "Turning boosting off keeps the same B0 ranking")
        home.query = "linear equations"; home.search(immediate: true)
        for _ in 0..<300 { if !home.searching { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(!home.searching && home.searchDuration != nil && home.searchDuration! >= 0, "Completed UI searches record their duration")
        home.resultOrder = .rank
        require(home.visibleHits.map(\.id) == home.results.map(\.id), "Rank navigation follows the engine's complete ordering")
        let completedDuration = home.searchDuration, completedSelection = home.selectedHit?.id, completedStart = home.searchStartedAt
        home.cancelExploration(); home.resumeSearch()
        require(!home.searching && home.searchDuration == completedDuration && home.selectedHit?.id == completedSelection && home.searchStartedAt == completedStart, "Returning from a reader reuses completed results, timing and selection")
        home.libraryRevision = UUID(); home.resumeSearch()
        require(!home.searching && home.searchDuration == nil && home.results.isEmpty, "An index revision invalidates retained results without starting inference")
        home.query = "A question still being written?"; home.editSearch()
        try await Task.sleep(for: .milliseconds(700))
        require(!home.searching && home.searchDuration == nil && home.results.isEmpty, "Editing a draft never starts retrieval or inference")
        home.query = "First question?"; home.search()
        home.query = ""; home.search(immediate: true)
        try await Task.sleep(for: .milliseconds(700))
        require(home.searchDuration == nil && home.results.isEmpty && !home.searching, "Clearing a pending search rejects stale results and timing")
        UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        for dark in [false, true] {
            let defaults = UserDefaults(suiteName: "remile.search-ui." + UUID().uuidString)!
            let host = NSHostingView(rootView: LibrarySearchSettings().defaultAppStorage(defaults).frame(width: 540, height: 600).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); raster(host, name: dark ? "search-dark" : "search-light"); window.orderOut(nil)
            let banner = NSHostingView(rootView: RemileBanner().frame(width: 920, height: 150).background(RemileStyle.background).environment(\.colorScheme, dark ? .dark : .light))
            let bannerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
            bannerWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); bannerWindow.contentView = banner; bannerWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); raster(banner, name: dark ? "banner-dark" : "banner-light"); bannerWindow.orderOut(nil)
            let beacon = NSHostingView(rootView: SearchWaitingView(startedAt: Date().addingTimeInterval(-2)).frame(width: 520, height: 280).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).environment(\.colorScheme, dark ? .dark : .light))
            let beaconWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
            beaconWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); beaconWindow.contentView = beacon; beaconWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); raster(beacon, name: dark ? "beacon-dark" : "beacon-light"); beaconWindow.orderOut(nil)
        }
        print("PASS: Search settings and lighthouse rendered in both appearances")
        print("PASS: Rendered all three AI settings modes with no account requests or saved preference changes")
        exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
}
app.run()
