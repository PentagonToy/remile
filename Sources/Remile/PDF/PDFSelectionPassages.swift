import PDFKit

extension PDFSelectionContext {
    /// Separate source locations for a selection spanning pages; never attribute all text to page one.
    func passages(path: String) -> [AssistantPassage] {
        guard document.allowsCopying else { return [] }
        var remaining = 8000
        return pageIndices.prefix(4).compactMap { index in
            guard let page = document.page(at: index), remaining > 0 else { return nil }
            let lines = selection.selectionsByLine().filter { $0.pages.first === page }.compactMap(\.string)
            let value = String(lines.joined(separator: "\n").prefix(min(4000, remaining))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }; remaining -= value.count
            return AssistantPassage(location: AssistantLocation(path: path, unit: index + 1, label: "Page \(index + 1)"), text: value)
        }
    }
}
