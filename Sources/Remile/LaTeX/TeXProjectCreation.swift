import Foundation
import Darwin

/// A new project starts in its own folder and never replaces an existing document.
enum TeXProjectCreation {
    static let source = """
    \\documentclass{article}

    \\begin{document}

    \\section*{Untitled}

    \\end{document}

    """
    static func create(at root: URL) throws {
        let manager = FileManager.default
        guard mkdir(root.path, 0o755) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try Data(source.utf8).write(to: root.appendingPathComponent("main.tex"), options: .withoutOverwriting) }
        catch { try? manager.removeItem(at: root); throw error }
    }
}
