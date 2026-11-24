import PDFKit

/// Track live widget values without serialising the document while the user types.
final class PDFFormEdits {
    private struct Value: Equatable {
        let text: String?
        let state: PDFWidgetCellState
        init(_ annotation: PDFAnnotation) {
            text = annotation.widgetStringValue
            state = annotation.buttonWidgetState
        }
    }
    private var fields: [(annotation: PDFAnnotation, baseline: Value)] = []
    private var observations: [NSKeyValueObservation] = []
    var hasFields: Bool { !fields.isEmpty }
    var hasChanges: Bool { fields.contains { Value($0.annotation) != $0.baseline } }

    func attach(_ document: PDFDocument?, changed: @escaping () -> Void) {
        observations = []; fields = []
        guard let document, !document.isLocked, let catalog = document.documentRef?.catalog else { return }
        var form: CGPDFDictionaryRef?, roots: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &roots), let roots, CGPDFArrayGetCount(roots) > 0 else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for field in page.annotations where field.type == "Widget" && field.widgetFieldType != .signature {
                fields.append((field, Value(field)))
                observations.append(field.observe(\.widgetStringValue, options: [.old, .new]) { _, change in
                    if change.oldValue != change.newValue { changed() }
                })
                if field.widgetFieldType == .button {
                    observations.append(field.observe(\.buttonWidgetState, options: [.old, .new]) { _, change in
                        if change.oldValue != change.newValue { changed() }
                    })
                }
            }
        }
    }
    func committed() { fields = fields.map { ($0.annotation, Value($0.annotation)) } }
}
