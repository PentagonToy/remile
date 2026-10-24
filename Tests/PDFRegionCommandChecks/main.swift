import AppKit
import CryptoKit

try MainActor.assumeIsolated {
NSApplication.shared.setActivationPolicy(.prohibited)
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let input = directory.appendingPathComponent("input.pdf")
let original = pdfImageFixture(rotation: 90)
try original.write(to: input)
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(value(), message) }
func reject(_ body: () throws -> Void) { checks += 1; do { try body(); fatalError("Expected rejection") } catch { } }
let result = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: nil, output: nil, expectedHash: nil)
let hash = result["sha256"] as! String
expect(hash == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(), "Exact original fingerprint")
expect((result["regions"] as! [[String: Any]]).count == 2, "CLI image regions")
let output = directory.appendingPathComponent("image.png")
_ = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: "image-1", output: output.path, expectedHash: hash)
expect(FileManager.default.fileExists(atPath: output.path), "Export PNG")
let after = try Data(contentsOf: input)
expect(after == original, "Export leaves source unchanged")
reject { _ = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: "image-1", output: output.path, expectedHash: hash) }
reject { _ = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: "image-1", output: directory.appendingPathComponent("unverified.png").path, expectedHash: nil) }
reject { _ = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: "image-1", output: directory.appendingPathComponent("wrong.png").path, expectedHash: String(repeating: "0", count: 64)) }
reject { _ = try PDFRegionCommands.response(path: input.path, page: 2, tables: false, region: nil, output: nil, expectedHash: nil) }
reject { _ = try PDFRegionCommands.response(path: input.path, page: 1, tables: false, region: "image-1", output: directory.appendingPathComponent("wrong.tsv").path, expectedHash: hash) }
print("PDF region commands: \(checks) checks passed")

}
