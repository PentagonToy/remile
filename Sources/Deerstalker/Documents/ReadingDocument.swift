import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let deerstalkerMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct ReadingDocument: FileDocument {
    enum Content {
        case markdown(String)
        case pdf(Data)
    }

    static var readableContentTypes: [UTType] { [.pdf, .deerstalkerMarkdown, .plainText] }
    static var writableContentTypes: [UTType] { [.deerstalkerMarkdown, .plainText, .pdf] }

    var content: Content

    init() {
        content = .markdown("")
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if configuration.contentType.conforms(to: .pdf) {
            content = .pdf(data)
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            content = .markdown(text)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .markdown(let text):
            guard !configuration.contentType.conforms(to: .pdf) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return FileWrapper(regularFileWithContents: Data(text.utf8))
        case .pdf(let data):
            guard configuration.contentType.conforms(to: .pdf) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            // The PDF session commits serialised annotation changes into this value.
            return FileWrapper(regularFileWithContents: data)
        }
    }
}
