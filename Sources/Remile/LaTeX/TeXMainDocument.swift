import Foundation

/// Opening an editor does not require compilable LaTeX.
enum TeXMainDocument {
    static func choose(sources: [String: String], saved: String?) -> String? {
        let files = sources.keys.filter { ($0 as NSString).pathExtension.lowercased() == "tex" }.sorted {
            let left = $0.split(separator: "/").count, right = $1.split(separator: "/").count
            return left == right ? $0 < $1 : left < right
        }
        if let saved, files.contains(saved) { return saved }
        if files.contains("main.tex") { return "main.tex" }
        return files.first { sources[$0]?.contains("\\documentclass") == true } ?? files.first
    }
}
