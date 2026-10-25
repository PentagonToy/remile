import Foundation

/// Project names come from the existing tree. Labels are refreshed only for changed source buffers.
@MainActor final class TeXLocalCompletion {
    private var indexed: [String: String] = [:]
    private var labels: [String: [String]] = [:]
    func context(_ source: String, selection: NSRange, file: String, paths: [String], buffers: [String: String]) -> EditorCompletion.Context? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let start = max(0, selection.location - 300), suffix = text.substring(with: NSRange(location: start, length: selection.location - start)) as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\\(includegraphics|input|include|ref|eqref|autoref|pageref)(?:\[[^\]\n]*\])?\{([^{}\n]*)$"#),
              let match = regex.firstMatch(in: suffix as String, range: NSRange(location: 0, length: suffix.length)) else { return nil }
        let command = suffix.substring(with: match.range(at: 1)), prefix = suffix.substring(with: match.range(at: 2))
        let line = suffix.substring(to: match.range.location).components(separatedBy: "\n").last ?? ""
        guard !line.contains("%") else { return nil }
        let names: [String]
        if ["ref", "eqref", "autoref", "pageref"].contains(command) {
            let sources = buffers.filter { $0.key.lowercased().hasSuffix(".tex") }
            indexed = indexed.filter { sources[$0.key] != nil }; labels = labels.filter { sources[$0.key] != nil }
            let label = try! NSRegularExpression(pattern: #"(?m)\\label\{([^{}\n]+)\}"#)
            for (path, value) in sources where indexed[path] != value {
                let uncommented = value.components(separatedBy: "\n").map { String($0.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }.joined(separator: "\n") as NSString
                labels[path] = label.matches(in: uncommented as String, range: NSRange(location: 0, length: uncommented.length)).map { uncommented.substring(with: $0.range(at: 1)) }
                indexed[path] = value
            }
            names = Array(Set(labels.values.flatMap { $0 })).sorted()
        } else {
            let extensions = command == "includegraphics" ? ["pdf", "png", "jpg", "jpeg", "eps", "svg"] : ["tex"]
            names = paths.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        }
        let candidates = names.filter { $0.localizedCaseInsensitiveContains(prefix) }
        guard !candidates.isEmpty else { return nil }
        return .init(range: NSRange(location: selection.location - (prefix as NSString).length, length: (prefix as NSString).length), items: Array(candidates.prefix(12)).map { .init(label: $0, insertion: $0) })
    }
}
