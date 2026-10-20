import SwiftUI
import Translation

struct SelectionTranslation: Identifiable {
    let id = UUID()
    let text: String
}

/// Apple's native language picker/translation UI manages supported languages and consent.
struct SelectionTranslationModifier: ViewModifier {
    @Binding var request: SelectionTranslation?
    func body(content: Content) -> some View {
        if #available(macOS 14.4, *) {
            content.translationPresentation(isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }), text: request?.text ?? "")
        } else {
            content.alert("Translation requires macOS 14.4 or later", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } })) { Button("OK") { request = nil } }
        }
    }
}
