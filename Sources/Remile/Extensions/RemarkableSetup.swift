import CryptoKit
import Foundation
import SwiftUI

struct RemarkableRuntimeManifest: Decodable {
    struct Asset: Decodable {
        let filename: String
        let url: URL
        let bytes: Int64
        let sha256: String
        var name: String?
        var version: String?
    }
    let schema: Int
    let id: String
    let pythonVersion: String
    let python: Asset
    let packages: [Asset]

    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "runtime", withExtension: "json", subdirectory: "Extensions/reMarkable") else {
            throw ReferenceFailure("The connection tools are missing from this app. Reinstall remile.")
        }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        func token(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.allSatisfy(safe.contains) && !text.contains("..") }
        guard value.schema == 1, token(value.id), token(value.pythonVersion), !value.packages.isEmpty,
              value.packages.count <= 40 else { throw ReferenceFailure("Invalid connection tools manifest.") }
        let assets = [value.python] + value.packages
        guard Set(assets.map(\.filename)).count == assets.count else { throw ReferenceFailure("Duplicate tool filenames.") }
        for asset in assets {
            guard token(asset.filename), asset.bytes > 0, asset.bytes <= 80_000_000,
                  asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit }),
                  allowed(asset.url) else { throw ReferenceFailure("Invalid connection tool download.") }
        }
        let packageNames = value.packages.compactMap(\.name).map { $0.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-") }
        guard Set(packageNames).count == value.packages.count else { throw ReferenceFailure("Duplicate connection packages.") }
        for asset in value.packages {
            guard asset.filename.hasSuffix(".whl"), let name = asset.name, token(name),
                  let version = asset.version, token(version), asset.url.host == "files.pythonhosted.org" else {
                throw ReferenceFailure("Invalid connection package.")
            }
        }
        return value
    }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil &&
            ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "files.pythonhosted.org"].contains(url.host ?? "")
    }
    static func verify(_ file: URL, asset: Asset) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == asset.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256.lowercased() else {
            throw ReferenceFailure("The downloaded tools could not be verified. Try again.")
        }
    }
}

private final class RemarkableToolDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(RemarkableRuntimeManifest.allowed) == true ? request : nil)
    }
}

actor RemarkableToolStorage {
    static let shared = RemarkableToolStorage()
    func publish(_ stage: URL, to destination: URL) throws {
        try Task.checkCancellation()
        try RemarkableExtensionAccess.requireEnabled()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
    func removeInstalled(in root: URL = RemarkableToolInstaller.root) throws {
        guard !UserDefaults.standard.bool(forKey: RemarkableExtensionAccess.enabledKey) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw ReferenceFailure("The connection tools folder is a link. Remove its tools manually.")
        }
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = folder.lastPathComponent
            let receipt = folder.appendingPathComponent("remile-runtime.json")
            let marker = try? String(contentsOf: receipt, encoding: .utf8)
            let managed = name.hasPrefix("Runtime-") && RemarkableToolInstaller.managedIDs.contains(marker ?? "")
            if name == "Runtime" || managed { try fm.removeItem(at: folder) }
        }
    }
}

enum RemarkableToolInstaller {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/local.remile.app/Extensions/reMarkable")
    static let managedIDs = ["remarkable-ink-0.3.0-py312-v1", "remarkable-cloud-0.3.1-py312-v1"]
    static let directory = "Runtime-remarkable-ink-0.3.0-py312-v1"
    static var installedPython: String {
        for id in managedIDs {
            let folder = root.appendingPathComponent("Runtime-" + id)
            let receipt = folder.appendingPathComponent("remile-runtime.json")
            let path = folder.appendingPathComponent("python/bin/python3").path
            if (try? String(contentsOf: receipt, encoding: .utf8)) == id,
                FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ""
    }
    static func run(_ executable: String, _ arguments: [String], in folder: URL, timeout: TimeInterval = 120) async throws -> String {
        let log = folder.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "TMPDIR": folder.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try Task.checkCancellation()
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline, (try handle.offset()) < 2_000_000 else { throw ReferenceFailure("Connection tools setup took too long. Try again.") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            for _ in 0..<10 where process.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        guard try handle.offset() <= 2_000_000 else { throw ReferenceFailure("Connection tools returned too much output.") }
        let data = try Data(contentsOf: log)
        guard process.terminationStatus == 0 else { throw ReferenceFailure("The connection tools could not be set up. Try again.") }
        return String(decoding: data, as: UTF8.self)
    }
    static func check(_ python: String, in folder: URL) async throws {
        _ = try await run(python, ["-I", "-B", "-c", "import rmc, rmscene"], in: folder, timeout: 20)
    }
    static func install(_ manifest: RemarkableRuntimeManifest, at root: URL = root,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> String {
        #if !arch(arm64)
        throw ReferenceFailure("Automatic setup requires an Apple silicon Mac.")
        #else
        try Task.checkCancellation()
        try RemarkableExtensionAccess.requireEnabled()
        try NetworkAccess.requireOnline()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let preferred = root.appendingPathComponent("Runtime-" + manifest.id)
        if fm.fileExists(atPath: preferred.path) {
            do { try await check(preferred.appendingPathComponent("python/bin/python3").path, in: root); return preferred.appendingPathComponent("python/bin/python3").path }
            catch is CancellationError { throw CancellationError() }
            catch { /* Keep the previous tools until their replacement is ready. */ }
        }
        let destination = fm.fileExists(atPath: preferred.path) ? root.appendingPathComponent("Runtime-" + manifest.id + "-" + UUID().uuidString) : preferred
        let stage = root.appendingPathComponent("Setup-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let free = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 500_000_000 else { throw ReferenceFailure("Free at least 500 MB to install connection tools.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let watch = try NetworkAccess.gate.watch(session)
        defer { NetworkAccess.gate.release(watch); session.invalidateAndCancel() }
        let assets = [manifest.python] + manifest.packages
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            try RemarkableExtensionAccess.requireEnabled()
            try NetworkAccess.requireOnline()
            await progress("Downloading tools \(index + 1) of \(assets.count)…")
            let (temporary, response) = try await session.download(from: asset.url, delegate: RemarkableToolDownload(limit: asset.bytes))
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReferenceFailure("Connection tools are unavailable. Try again later.") }
            try RemarkableRuntimeManifest.verify(temporary, asset: asset)
            try fm.moveItem(at: temporary, to: stage.appendingPathComponent(asset.filename))
        }
        await progress("Installing connection tools…")
        let archive = stage.appendingPathComponent(manifest.python.filename).path
        let listing = try await run("/usr/bin/tar", ["-tzf", archive], in: stage)
        guard listing.split(separator: "\n").allSatisfy({ entry in
            let parts = entry.split(separator: "/")
            return parts.first == "python" && !parts.contains("..") && !entry.hasPrefix("/")
        }) else { throw ReferenceFailure("Invalid tools archive.") }
        _ = try await run("/usr/bin/tar", ["-xzf", archive], in: stage)
        let python = stage.appendingPathComponent("python/bin/python3").path
        let requirements = manifest.packages.map { "\($0.name!)==\($0.version!) --hash=sha256:\($0.sha256)" }.joined(separator: "\n")
        try requirements.write(to: stage.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        _ = try await run(python, ["-I", "-B", "-m", "pip", "--isolated", "install", "--no-index", "--find-links", stage.path,
                                  "--no-deps", "--only-binary=:all:", "--require-hashes", "--no-compile", "-r", stage.appendingPathComponent("requirements.txt").path], in: stage)
        _ = try await run(python, ["-I", "-B", "-m", "pip", "check"], in: stage)
        try await check(python, in: stage)
        let versions = Dictionary(uniqueKeysWithValues: manifest.packages.map { ($0.name!, $0.version!) })
        let expected = String(decoding: try JSONSerialization.data(withJSONObject: versions), as: UTF8.self)
        let script = "import json,sys,platform,importlib.metadata as m; expected=json.loads(sys.argv[1]); assert platform.python_version()==sys.argv[2] and platform.machine()=='arm64'; assert all(m.version(k)==v for k,v in expected.items())"
        _ = try await run(python, ["-I", "-B", "-c", script, expected, manifest.pythonVersion], in: stage)
        for asset in assets { try fm.removeItem(at: stage.appendingPathComponent(asset.filename)) }
        try fm.removeItem(at: stage.appendingPathComponent("requirements.txt"))
        try Data(manifest.id.utf8).write(to: stage.appendingPathComponent("remile-runtime.json"), options: .atomic)
        try Task.checkCancellation()
        try await RemarkableToolStorage.shared.publish(stage, to: destination)
        return destination.appendingPathComponent("python/bin/python3").path
        #endif
    }
}

@MainActor final class RemarkableSetupModel: ObservableObject {
    @Published var busy = false
    @Published var phase = ""
    @Published var error: String?
    @Published var ready = false
    private var task: Task<Void, Never>?
    func check() {
        guard !busy else { return }
        let python = RemarkableRuntime.python
        guard !python.isEmpty else { return }
        busy = true; ready = false; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await RemarkableToolInstaller.check(python, in: FileManager.default.temporaryDirectory)
                try Task.checkCancellation()
                ready = true
            } catch is CancellationError {} catch { self.error = "The existing connection tools need attention. Choose a working helper or download the tools." }
        }
    }
    func install() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; phase = ""; task = nil }
            do {
                try RemarkableExtensionAccess.requireEnabled()
                let manifest = try RemarkableRuntimeManifest.load()
                let path = try await RemarkableToolInstaller.install(manifest) { [self] message in
                    await MainActor.run { self.phase = message }
                }
                UserDefaults.standard.set(path, forKey: "extensions.remarkable.python")
                ready = true
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() { task?.cancel() }
}

struct RemarkableConsent: View {
    let agree: () -> Void
    let disagree: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing * 2) {
            Text("Enable reMarkable?").font(RemileType.heading)
            Text("Read documents and handwriting directly from your device over SSH. Your password stays in this Mac’s Keychain.")
            Text("Developer mode and SSH access must already be enabled. remile does not change device settings or files.")
                .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            HStack {
                Spacer()
                Button("Disagree", action: disagree).keyboardShortcut(.cancelAction)
                Button("Agree", action: agree).keyboardShortcut(.defaultAction)
            }
        }.fixedSize(horizontal: false, vertical: true).padding(RemileControl.rowSpacing * 2)
            .frame(width: 440).background(RemileStyle.background).tint(RemileStyle.accent)
    }
}

struct RemarkableSetup: View {
    @StateObject private var model = RemarkableSetupModel()
    @AppStorage(RemarkableExtensionAccess.enabledKey) private var enabled = false
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing * 2) {
            HStack { Text("Connection tools").font(RemileType.heading); Spacer(); Button("Done", action: done) }
            if model.ready {
                Text("Ready. Click the reMarkable card to connect.")
            } else {
                Text("Download the tools to this Mac. No separate Python setup is needed.")
                Text("About 26 MB to download. Installed only for remile.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                if model.busy {
                    HStack { ProgressView().controlSize(.small); Text(model.phase.isEmpty ? "Checking tools…" : model.phase); Spacer(); Button("Cancel") { model.cancel() } }
                } else { Button("Download and install") { model.install() }.keyboardShortcut(.defaultAction) }
                if let error = model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
                DisclosureGroup("Existing tools") {
                    Button("Choose connection helper…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            UserDefaults.standard.set(url.path, forKey: "extensions.remarkable.python")
                            model.check()
                        }
                    }.disabled(model.busy)
                }.font(RemileType.caption)
            }
        }.fixedSize(horizontal: false, vertical: true).padding(RemileControl.rowSpacing * 2).frame(width: 440)
            .background(RemileStyle.background).tint(RemileStyle.accent)
            .task { model.check() }.onChange(of: enabled) { _, value in if !value { model.cancel(); done() } }.onDisappear { model.cancel() }
    }
}
