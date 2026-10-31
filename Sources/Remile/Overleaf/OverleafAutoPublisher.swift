import Foundation

enum OverleafAutoPublisher {
    static func head(_ root: URL) throws -> String {
        try OverleafGit.run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
