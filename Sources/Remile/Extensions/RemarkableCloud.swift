import AppKit
import Foundation
import PDFKit
import Security

enum RemarkableExtensionAccess {
    static let enabledKey = "extensions.remarkable.enabled"
    static let consentKey = "extensions.remarkable.consent"
    static let consentVersion = 2
    static func requireEnabled(in defaults: UserDefaults = .standard) throws {
        guard defaults.bool(forKey: enabledKey), defaults.integer(forKey: consentKey) == consentVersion else { throw ReferenceFailure("Enable reMarkable in Extensions.") }
    }
}

struct RemarkableCloudItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let revision: String
    var parentID: String? = nil
    var folder: Bool? = nil
    var isFolder: Bool { folder == true }
    static func selectionBatches(_ ids: Set<String>) -> [[String]] {
        let ordered = ids.sorted()
        return stride(from: 0, to: ordered.count, by: 200).map { Array(ordered[$0..<min($0 + 200, ordered.count)]) }
    }
    var createdTime: String? = nil
    var createdDate: Date? {
        guard let raw = createdTime, let value = Double(raw), value.isFinite, value > 0, value < 253402300799000 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
    var modifiedTime: String? = nil
    var modifiedDate: Date? {
        guard let raw = modifiedTime, let value = Double(raw), value.isFinite, value > 0, value < 253402300799000 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
    var fileType: String? = nil
    var fields: [String: String]? = nil
}
struct RemarkableFolderScope: Codable, Equatable, Identifiable, Sendable {
    static let unfiledID = ":unfiled"
    var id: String
    var name: String
}

struct RemarkableCloudReply: Decodable, Sendable {
    struct Page: Decodable, Sendable {
        let id: String
        let backgroundPage: Int?
        let svg: String?
        let bounds: [Double]?
    }
    let ok: Bool
    var error: String?
    var warning: String?
    var token: String?
    var documents: [RemarkableCloudItem]?
    var pages: [Page]?
    var background: String?
    var revision: String?
}

enum RemarkableCredentials {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.remile.extensions.remarkable", kSecAttrAccount as String: "ssh-device",
            kSecAttrSynchronizable as String: false,
        ]
    }
    static func exists(matching item: [String: Any]? = nil) -> Bool {
        let request = (item ?? query).merging([
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        return KeychainAccess.read(matching: request, interactive: false).status == errSecSuccess
    }
    static func read(interactive: Bool = false) -> String? { read(matching: query, interactive: interactive) }
    static func read(matching item: [String: Any], interactive: Bool = false) -> String? {
        let request = item.merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        return KeychainAccess.data(matching: request, interactive: interactive)
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    static func save(_ token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 16000,
            KeychainAccess.store(
                Data(token.utf8), matching: query,
                attributes: [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly])
                == errSecSuccess
        else {
            throw ReferenceFailure(
                "The connection could not be saved in Keychain. Your account has not been connected.")
        }
    }
    static func remove() throws {
        let result = KeychainAccess.remove(matching: query)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw ReferenceFailure("Keychain could not remove the connection. Try again.")
        }
    }
}

/// Retain an approved credential only for this model's lifetime, never in preferences or files.
@MainActor final class RemarkableCredentialSession {
    private var token: String?
    private let reader: (Bool) -> String?
    init(reader: @escaping (Bool) -> String? = { RemarkableCredentials.read(interactive: $0) }) { self.reader = reader }
    func read(interactive: Bool = false) -> String? {
        if let token { return token }
        token = reader(interactive)
        return token
    }
    func remember(_ token: String) { self.token = token }
    func clear() { token = nil }
}

actor RemarkableCloudWorker {
    func call(
        python: String, operation: String, token: String? = nil, code: String? = nil, id: String? = nil,
        directory: URL? = nil, ids: [String]? = nil
    ) async throws -> RemarkableCloudReply {
        try Task.checkCancellation()
        try RemarkableExtensionAccess.requireEnabled()
        try NetworkAccess.requireOnline()
        guard python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else {
            throw ReferenceFailure("Set up connection tools in Extensions.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            Bundle.main.resourceURL?.appendingPathComponent("Extensions/reMarkable/ssh.py"),
            root.appendingPathComponent("others/extensions/remarkable/ssh.py"),
        ].compactMap { $0 }
        guard let script = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ReferenceFailure("The reMarkable connection helper is missing.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remile-cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("reply.json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", script.path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
        ]
        process.standardInput = input
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        var request: [String: Any] = ["operation": operation]
        if let token { request["token"] = token }
        if let code { request["code"] = code }
        if let id { request["id"] = id }
        if let directory { request["directory"] = directory.path }
        if let ids { request["ids"] = ids }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= 32768 else { throw ReferenceFailure("The connection request exceeds its limit.") }
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now.advanced(
                by: .seconds(["receive", "describe"].contains(operation) ? 180 : 90))
            while process.isRunning {
                try Task.checkCancellation()
                try RemarkableExtensionAccess.requireEnabled()
                try NetworkAccess.requireOnline()
                let bytes = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard bytes <= 4_000_000, ContinuousClock.now < deadline else {
                    throw ReferenceFailure(
                        "The device request exceeded its time or output limit. Try a smaller document.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning {
                // The SSH helper creates a process group so cancellation also stops transfers.
                kill(-process.processIdentifier, SIGTERM)
                if process.isRunning { process.terminate() }
                for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                if process.isRunning { kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: output)
        guard bytes.count <= 4_000_000, process.terminationStatus == 0 else {
            throw ReferenceFailure("The connection helper could not complete the request.")
        }
        let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: bytes)
        guard reply.ok else { throw ReferenceFailure(reply.error ?? "The device request failed.") }
        return reply
    }
}

/// Experimental Paper Pro Move canvas. Custom transforms fail in the helper rather than moving ink silently.
enum RemarkablePDF {
    static func render(_ reply: RemarkableCloudReply, in folder: URL) throws -> URL {
        guard let pages = reply.pages, !pages.isEmpty, pages.count <= 500 else {
            throw ReferenceFailure("The received document has no supported pages.")
        }
        let background: PDFDocument?
        if let path = reply.background {
            background = PDFDocument(url: try child(path, in: folder))
        } else {
            background = nil
        }
        if reply.background != nil && background == nil {
            throw ReferenceFailure("The original PDF could not be opened.")
        }
        let file = folder.appendingPathComponent("received.pdf")
        if let background, let path = reply.background, pages.count == background.pageCount,
            pages.enumerated().allSatisfy({ $0.element.svg == nil && $0.element.backgroundPage == $0.offset }) {
            // Preserve the complete original, including its text encoding and metadata.
            let original = try Data(contentsOf: child(path, in: folder), options: .mappedIfSafe)
            try original.write(to: file, options: .atomic)
            return file
        }
        // Older notebooks retain a wider canvas even when opened on a Move.
        // Expand to the generated ink bounds rather than clipping those pages.
        let inkBounds = pages.compactMap(\.bounds)
        guard inkBounds.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0.isFinite && abs($0) <= 10000 } }) else {
            throw ReferenceFailure("Unsupported ink bounds.")
        }
        let halfWidth = inkBounds.reduce(954 * 72.0 / 226 / 2) { width, box in
            max(width, abs(box[0]), abs(box[0] + box[2]))
        }
        let topPadding = max(0, -(inkBounds.map { $0[1] }.min() ?? 0))
        let bottom = inkBounds.reduce(1696 * 72.0 / 226) { height, box in max(height, box[1] + box[3]) }
        let canvas = CGSize(width: halfWidth * 2, height: bottom + topPadding)
        var mediaBox = CGRect(origin: .zero, size: canvas)
        let renderedFile = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: renderedFile) }
        guard let consumer = CGDataConsumer(url: renderedFile as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        for page in pages {
            try Task.checkCancellation()
            try autoreleasepool {
                let source: PDFPage?
                if let index = page.backgroundPage {
                    guard let document = background, index >= 0, index < document.pageCount,
                        let original = document.page(at: index), page.svg == nil || original.rotation == 0
                    else {
                        throw ReferenceFailure(
                            "This PDF page layout is not supported yet. Export it from reMarkable instead.")
                    }
                    source = original
                } else {
                    source = nil
                }
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(origin: .zero, size: canvas))
                if let source, page.svg != nil {
                    let bounds = source.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0 else { throw ReferenceFailure("Invalid PDF page size.") }
                    let scale = min(canvas.width / bounds.width, canvas.height / bounds.height)
                    context.saveGState()
                    context.translateBy(
                        x: (canvas.width - bounds.width * scale) / 2, y: (canvas.height - bounds.height * scale) / 2)
                    context.scaleBy(x: scale, y: scale)
                    source.draw(with: .mediaBox, to: context)
                    context.restoreGState()
                }
                if let svg = page.svg {
                    guard let box = page.bounds, box.count == 4, box.allSatisfy({ $0.isFinite && abs($0) <= 10000 }),
                        box[2] > 0, box[3] > 0,
                        let image = NSImage(contentsOf: try child(svg, in: folder))
                    else { throw ReferenceFailure("The handwriting could not be rendered.") }
                    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = graphics
                    image.draw(
                        in: CGRect(
                            x: canvas.width / 2 + box[0], y: canvas.height - topPadding - box[1] - box[3],
                            width: box[2],
                            height: box[3]), from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                context.endPDFPage()
            }
        }
        context.closePDF()
        guard let result = PDFDocument(url: renderedFile), result.pageCount == pages.count else {
            throw ReferenceFailure("The received PDF is incomplete.")
        }
        // Copy unmarked source pages instead of fitting them to the device canvas.
        // This also retains searchable text, page boxes, rotation and PDF annotations.
        for (index, page) in pages.enumerated() where page.svg == nil {
            try Task.checkCancellation()
            guard let originalIndex = page.backgroundPage else { continue }
            guard let original = background?.page(at: originalIndex)?.copy() as? PDFPage else {
                throw ReferenceFailure("The original PDF page could not be preserved.")
            }
            result.removePage(at: index)
            result.insert(original, at: index)
        }
        if let attributes = background?.documentAttributes { result.documentAttributes = attributes }
        guard result.write(to: file) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }
    static func child(_ name: String, in root: URL) throws -> URL {
        var component = root
        for part in name.split(separator: "/") {
            component.appendPathComponent(String(part))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) == nil else {
                throw ReferenceFailure("Symbolic links are not permitted in received documents.")
            }
        }
        let path = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard !name.hasPrefix("/"), path.path.hasPrefix(parent) else {
            throw ReferenceFailure("Unsafe received document path.")
        }
        return path
    }
}
