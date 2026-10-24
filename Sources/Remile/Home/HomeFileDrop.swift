import SwiftUI
import UniformTypeIdentifiers

/// Card destinations consume their own drops, including validation errors.
enum HomeFileDrop {
    enum Target { case open, convert, compress, combine, latex }
    enum Plan { case open(URL), convert([URL]), compress(URL), combine([URL]), latex(URL) }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    @MainActor static func receive(_ providers: [NSItemProvider], perform: @escaping ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        continuation.resume(returning: url)
                    }
                }
                guard let url else { perform([]); return }
                urls.append(url)
            }
            perform(urls)
        }
    }
    static func plan(_ urls: [URL], target: Target) throws -> Plan {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw Failure(message: "Drop local files from Finder.") }
        switch target {
        case .open:
            guard urls.count == 1, ["pdf", "md", "markdown", "txt", "docx"].contains(urls[0].pathExtension.lowercased()) else { throw Failure(message: "Drop one PDF, Markdown or DOCX document.") }
            return .open(urls[0])
        case .latex:
            guard urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || urls[0].pathExtension.lowercased() == "zip" else { throw Failure(message: "Drop one LaTeX source ZIP or project folder.") }
            return .latex(urls[0].standardizedFileURL)
        case .convert:
            guard urls.allSatisfy({ url in
                ["md", "markdown", "doc", "docx"].contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }) else { throw Failure(message: "Convert accepts images, Word and Markdown files.") }
            return .convert(urls)
        case .compress:
            guard urls.count == 1, urls[0].pathExtension.lowercased() == "pdf" else { throw Failure(message: "Drop one PDF onto Compress.") }
            return .compress(urls[0])
        case .combine:
            guard urls.count >= 2 else { throw Failure(message: "Choose at least two files to combine.") }
            _ = try DocumentTools.kind(urls)
            return .combine(urls)
        }
    }
}

extension HomeModel {
    func presentConversion(_ urls: [URL] = []) {
        conversion = ConversionModel(); conversion.add(urls); convertPresented = true
    }
    func presentCompression(_ url: URL? = nil) {
        compression = CompressionModel(); if let url { compression.add(url) }; compressPresented = true
    }
    func handleDrop(_ urls: [URL], target: HomeFileDrop.Target) {
        guard !processing, !opening, !convertPresented, !compressPresented else { return }
        do {
            switch try HomeFileDrop.plan(urls, target: target) {
            case .open(let url): open(url)
            case .latex(let root): if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true && root.pathExtension.lowercased() == "zip" { importTeXArchive(root) } else { openTeX(root) }
            case .convert(let urls): presentConversion(urls)
            case .compress(let url): presentCompression(url)
            case .combine(let urls): Task { @MainActor in self.create(.combine, inputs: urls, open: { self.open($0) }) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ToolFileDrop: ViewModifier {
    let model: HomeModel
    let target: HomeFileDrop.Target
    @StateObject private var hover = Hover()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class Hover: ObservableObject { @Published var active = false }
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RemileStyle.accent.opacity(hover.active ? 0.9 : 0), lineWidth: 2).allowsHitTesting(false))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover.active)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $hover.active) { providers in
                HomeFileDrop.receive(providers) { model.handleDrop($0, target: target) }; return true
            }
    }
}
