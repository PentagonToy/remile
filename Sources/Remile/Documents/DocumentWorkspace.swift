import SwiftUI

struct DocumentWorkspace: View {
    @Binding var document: ReadingDocument
    var fileURL: URL? = nil
    var session: ReadingSession? = nil

    var body: some View {
        switch document.content {
        case .pdf(let data):
            PDFWorkspace(data: data, fileURL: fileURL, readingSession: session) { data in document.content = .pdf(data) }
        case .markdown:
            MarkdownWorkspace(source: markdownSource, mode: fileURL?.path.hasPrefix("/remile-untitled-") == true ? .split : .read, fileURL: fileURL, session: session)
        }
    }

    private var markdownSource: Binding<String> {
        Binding {
            guard case .markdown(let source) = document.content else { return "" }
            return source
        } set: { source in
            document.content = .markdown(source)
        }
    }
}
