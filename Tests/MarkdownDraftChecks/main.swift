import Foundation
import PDFKit

Task { @MainActor in
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let reader = ReadingSession()
        precondition(reader.newMarkdown() && !reader.dirty, "New empty draft is clean")
        precondition(reader.close(), "Empty draft closes without a save question")
        precondition(reader.newMarkdown(), "Reopen an empty draft")
        reader.document.content = .markdown("A note")
        precondition(reader.dirty, "Typed content needs confirmation")
        reader.document.content = .markdown(" \n")
        precondition(reader.dirty, "Intentional whitespace is retained")
        reader.document.content = .markdown("")
        precondition(!reader.dirty && reader.close(), "A cleared new draft can close")
        let file = output.appendingPathComponent("existing.md")
        try Data("Saved content".utf8).write(to: file)
        try reader.open(file, recordRecent: false)
        reader.document.content = .markdown("")
        precondition(reader.dirty, "Clearing an existing file remains a real edit")
        reader.document.content = .markdown("Saved content")
        precondition(!reader.dirty, "Restoring the saved bytes is clean")
        print("Passed 7 Markdown draft checks")
        exit(0)
    } catch { fatalError(String(describing: error)) }
}
RunLoop.main.run()
