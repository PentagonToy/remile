import AppKit
import SwiftUI
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1; print("PASS: " + name); fflush(stdout) }
@MainActor func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool) async throws {
    let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let controller = NSHostingController(rootView: view.font(RemileType.control).buttonStyle(RemileActionStyle()).environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
    controller.sizingOptions = []
    let host = controller.view
    window.contentViewController = controller; window.setContentSize(size); host.frame = .init(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // A bounded run-loop turn lets AppKit realise controls without driving input or network requests.
    try await Task.sleep(for: .milliseconds(120))
    host.layoutSubtreeIfNeeded()
    let measured = controller.sizeThatFits(in: size)
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    print("SIZE: \(name) \(measured) within \(size)"); fflush(stdout)
    check(measured.width <= size.width + 1, name + " fits horizontally")
    check(measured.height <= size.height + 1, name + " fits vertically")
    window.orderOut(nil)
}
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var preferences = original; preferences[NetworkAccessGate.preference] = true; preferences["assistant.provider"] = "Off"
        preferences[AnimationPolicy.preference] = false
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let library = OverleafLibrary(directory: output.appendingPathComponent("fixture-library"))
        let free = library.saveAccount(name: "A long account name for layout checks", token: "", plan: .free)!
        let premium = library.saveAccount(name: "Research", token: "", plan: .premium)!
        let home = HomeModel(index: LibraryIndex(location: output.appendingPathComponent("search.sqlite")), overleaf: library)
        let references = ReferenceModel(repository: ReferenceRepository(root: output.appendingPathComponent("references")))
        let projectRoot = output.appendingPathComponent("tex-project")
        try TeXProjectCreation.create(at: projectRoot)
        let project = try TeXProject(projectRoot, historyEnabled: false)
        let pdf = PDFDocument(); let page = PDFPage(image: NSImage(size: NSSize(width: 400, height: 550), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true })!
        pdf.insert(page, at: 0); let data = pdf.dataRepresentation()!
        let markdown = "# A calm workspace\n\nText stays readable while the controls keep their own scale."
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for width in [CGFloat(640), CGFloat(1200)] {
                let size = CGSize(width: width, height: 700), suffix = "-\(Int(width))-" + theme
                try await render(LibrarySearchView(model: home, open: { _ in }, goHome: {}), name: "search" + suffix, size: size, dark: dark)
                try await render(MarkdownWorkspace(source: .constant(markdown), mode: .split), name: "markdown" + suffix, size: size, dark: dark)
                try await render(TeXWorkspace(project: project, close: {}), name: "latex" + suffix, size: size, dark: dark)
                try await render(PDFWorkspace(data: data, updateDocument: { _ in }), name: "pdf" + suffix, size: size, dark: dark)
                try await render(ReferenceWorkspace(model: references, goHome: {}), name: "reference" + suffix, size: size, dark: dark)
                try await render(WriterWorkspace(model: WriterModel(), goHome: {}), name: "writer" + suffix, size: size, dark: dark)
                library.importSize = size
                try await render(OverleafProjects(library: library, open: { _ in }, prepareRemoval: { _ in true }), name: "overleaf" + suffix, size: size, dark: dark)
            }
            try await render(OverleafAccountManager(library: library, selected: free.id, prepareRemoval: { _ in true }, close: {}), name: "account-free-" + theme, size: CGSize(width: 680, height: 500), dark: dark)
            try await render(OverleafAccountManager(library: library, selected: premium.id, requestGitToken: true, prepareRemoval: { _ in true }, close: {}), name: "account-git-" + theme, size: CGSize(width: 680, height: 500), dark: dark)
            try await render(ReaderSettings(), name: "settings-" + theme, size: CGSize(width: 720, height: 560), dark: dark)
            try await render(MarkdownSettings(), name: "markdown-settings-" + theme, size: CGSize(width: 440, height: 460), dark: dark)
            try await render(PDFSettingsForm(), name: "pdf-settings-" + theme, size: CGSize(width: 550, height: 480), dark: dark)
        }
        print("Passed \(checks) cross-workspace layout checks")
        exit(0)
    } catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
