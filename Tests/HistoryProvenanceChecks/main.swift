let before = "012ABC678"
precondition(EditorProvenance.rebase([NSRange(location: 3, length: 3)], before: before, after: "xx" + before) == [NSRange(location: 5, length: 3)])
precondition(EditorProvenance.rebase([NSRange(location: 3, length: 3)], before: before, after: "012AXC678") == [NSRange(location: 3, length: 1), NSRange(location: 5, length: 1)])
precondition(EditorProvenance.rebase([NSRange(location: 3, length: 3)], before: before, after: "012678").isEmpty)
precondition(EditorProvenance.change(before: "ab", after: "a😀b").inserted == NSRange(location: 1, length: 2))
precondition(EditorProvenance.merged([NSRange(location: 1, length: 3), NSRange(location: 3, length: 4)]) == [NSRange(location: 1, length: 6)])
precondition(EditorProvenance.merged((0..<600).map { NSRange(location: $0 * 3, length: 1) }).count == 256)
precondition(!TeXHistory.substantial("Hello", "Hello!"))
precondition(TeXHistory.substantial("Hello", "Hello and a substantially longer edit"))
let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("history-" + UUID().uuidString)
let folder = TeXHistory.directory(root)
defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
let initial = try TeXHistory.record(root: root, file: "main.tex", source: "Hello", previous: [])!
let duplicate = try TeXHistory.record(root: root, file: "main.tex", source: "Hello", previous: [initial])
precondition(duplicate == nil)
precondition(TeXHistory.read(root).count == 1)
let marked = try TeXHistory.record(root: root, file: "main.tex", source: "Hello", marker: "Before · tool", previous: [initial])!
precondition(marked.marker != nil && TeXHistory.read(root).count == 2)
precondition(TeXHistory.retained(Array(repeating: initial, count: 100)).count == 50)
precondition(TeXHistory.retained((0..<8).map { _ in TeXHistory.Revision(file: "large", source: String(repeating: "x", count: 3_000_000)) }).count == 5)
print("Passed history/provenance: deduplication, marked checkpoints, change threshold, count/byte bounds, range rebasing, local-overlap removal and Unicode offsets")

var tracker = EditorProvenance.Tracker()
let oldCommand = "Hello \\textbff{world}", fixedCommand = "Hello \\textbf{world}"
tracker.mark(before: oldCommand, after: fixedCommand)
precondition(!tracker.ranges.isEmpty)
precondition((fixedCommand as NSString).substring(with: tracker.ranges[0]).contains("textbf"))
tracker.transition(before: fixedCommand, after: oldCommand)
precondition(tracker.ranges.isEmpty)
precondition(EditorProvenance.highlight(before: "😀x", after: "😀").length == 2)
print("Passed deletion highlighting, native Undo restoration and composed-character checks")
