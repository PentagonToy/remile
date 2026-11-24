import AppKit
import Security
import Darwin

/// Copy and verify before atomically replacing an installed app.
enum AppInstallation {
    static let identifier = "local.remile.app"
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func shouldOffer(application: URL, readOnlyVolume: Bool) -> Bool {
        application.isFileURL && application.pathExtension == "app" && readOnlyVolume
    }
    static func isNewer(installed: Bundle, source: Bundle) -> Bool {
        let current = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let proposed = source.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return current.compare(proposed, options: .numeric) == .orderedDescending
    }
    private static func checkBundle(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              Bundle(url: url)?.bundleIdentifier == identifier else {
            throw Failure(message: "Another item named remile.app is already there. Move it before installing.")
        }
    }
    static func verify(_ url: URL) throws {
        try checkBundle(url)
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"local.remile.app\" and certificate leaf[subject.OU] = \"C5MK8PL46P\""
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure(message: "The app could not be verified. Download remile. again.")
        }
    }
    static func stage(source: URL, destination: URL, validate: (URL) throws -> Void = verify) throws -> URL {
        let manager = FileManager.default
        try checkBundle(source)
        if manager.fileExists(atPath: destination.path) { try checkBundle(destination) }
        let folder = destination.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".remile-install-" + UUID().uuidString + ".app")
        do {
            try manager.copyItem(at: source, to: staged)
            try validate(staged)
            return staged
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }
    static func commit(staged: URL, destination: URL, validate: (URL) throws -> Void = verify) throws {
        guard staged.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL,
              staged.lastPathComponent.hasPrefix(".remile-install-"), staged != destination else { throw CocoaError(.fileWriteInvalidFileName) }
        try validate(staged)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists { try checkBundle(destination) }
        let flags = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if exists { try? FileManager.default.removeItem(at: staged) }
    }

    @MainActor static func runIfNeeded(application: URL = Bundle.main.bundleURL) -> Bool {
        let readOnly = (try? application.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        guard shouldOffer(application: application, readOnlyVolume: readOnly) else { return false }
        let manager = FileManager.default
        let local = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = manager.isWritableFile(atPath: local.path) ? local : manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let destination = folder.appendingPathComponent("remile.app", isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = InstallationDelegate(application: application, destination: destination)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }
    @MainActor private static func present(application: URL, destination: URL, delegate: InstallationDelegate) {
        let app = NSApplication.shared
        let manager = FileManager.default
        app.activate(ignoringOtherApps: true)
        let sourceBundle = Bundle(url: application) ?? .main
        let newer = Bundle(url: destination).map { $0.bundleIdentifier == identifier && isNewer(installed: $0, source: sourceBundle) } ?? false
        let alert = NSAlert()
        alert.messageText = newer ? "A newer remile. is installed" : "Install remile."
        alert.informativeText = newer ? "Open the version in Applications." : "Copy remile. to Applications and open it." + (manager.fileExists(atPath: destination.path) ? " Your documents and settings stay unchanged." : "")
        alert.addButton(withTitle: newer ? "Open remile." : "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { app.terminate(nil); return }
        let progress = progressWindow()
        progress.makeKeyAndOrderFront(nil)
        delegate.installing = true
        Task { @MainActor in
            var installed = false
            var failure: Error?
            do {
                var staged: URL?
                defer { if let staged { try? manager.removeItem(at: staged) } }
                if !newer {
                    let candidate = try await Task.detached(priority: .userInitiated) { try stage(source: application, destination: destination) }.value
                    staged = candidate
                    try await closeInstalledCopy(at: destination)
                    try await Task.detached(priority: .userInitiated) { try commit(staged: candidate, destination: destination) }.value
                    installed = true
                } else {
                    try await Task.detached(priority: .userInitiated) { try verify(destination) }.value
                    installed = true
                }
                try await launch(destination, documents: delegate.documents, newInstance: !newer)
            } catch { failure = error }
            progress.orderOut(nil)
            if let failure {
                let error = NSAlert()
                error.messageText = installed ? "remile. is installed" : "Could not install remile."
                error.informativeText = installed ? "Open remile. from Applications." : failure.localizedDescription + " You can also drag remile.app to Applications in Finder."
                error.addButton(withTitle: "OK")
                error.runModal()
            }
            delegate.installing = false
            app.terminate(nil)
        }
    }
    @MainActor private static func progressWindow() -> NSWindow {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Installing remile."
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Preparing remile. in Applications…")
        let content = NSStackView(views: [spinner, label])
        content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        if let root = window.contentView {
            NSLayoutConstraint.activate([content.centerYAnchor.constraint(equalTo: root.centerYAnchor), content.centerXAnchor.constraint(equalTo: root.centerXAnchor)])
        }
        window.center()
        return window
    }
    @MainActor private static func closeInstalledCopy(at destination: URL) async throws {
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
        for copy in copies {
            copy.activate(options: [])
            guard copy.terminate() else { throw Failure(message: "Quit remile. and try installing again.") }
        }
        let deadline = Date().addingTimeInterval(60)
        while copies.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { throw Failure(message: "Finish saving your work and quit remile., then try again.") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    @MainActor private static func launch(_ application: URL, documents: [URL], newInstance: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { running, error in
                if let error { continuation.resume(throwing: error) }
                else if running != nil { continuation.resume() }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
            if documents.isEmpty { NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: completion) }
            else { NSWorkspace.shared.open(documents, withApplicationAt: application, configuration: configuration, completionHandler: completion) }
        }
    }
    @MainActor private final class InstallationDelegate: NSObject, NSApplicationDelegate {
        let application: URL
        let destination: URL
        var documents: [URL] = []
        var installing = false
        init(application: URL, destination: URL) { self.application = application; self.destination = destination }
        func applicationDidFinishLaunching(_ notification: Notification) {
            AppInstallation.present(application: application, destination: destination, delegate: self)
        }
        func application(_ application: NSApplication, open urls: [URL]) { documents.append(contentsOf: urls) }
        func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { installing ? .terminateCancel : .terminateNow }
    }
}
