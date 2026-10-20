import SwiftUI

struct MarkdownWorkspace: View {
    enum Mode: String, CaseIterable, Identifiable {
        case read = "Read"
        case edit = "Edit"
        case split = "Split"

        var id: Self { self }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var source: String
    @StateObject private var presentation: Presentation
    @StateObject private var zoom = ReaderZoom(text: true)

    init(source: Binding<String>, mode: Mode = .read) {
        _source = source; _presentation = StateObject(wrappedValue: Presentation(mode: mode))
    }
    final class Presentation: ObservableObject {
        @Published var mode: Mode
        init(mode: Mode) { self.mode = mode }
    }

    var body: some View {
        Group {
            switch presentation.mode {
            case .read:
                MarkdownPreview(source: source, scale: zoom.scale, wide: zoom.wide)
            case .edit:
                editor
            case .split:
                HSplitView {
                    editor.frame(minWidth: 260)
                    MarkdownPreview(source: source, scale: zoom.scale, wide: zoom.wide).frame(minWidth: 260)
                }
            }
        }
        .animation(reduceMotion ? nil : DeerMotion.panel, value: presentation.mode)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ReaderZoomControls(zoom: zoom, text: true) }
            ToolbarItem(placement: .primaryAction) {
                Picker("Document mode", selection: $presentation.mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $source)
            .font(.system(size: 14 * zoom.scale, design: .monospaced))
            .padding(12)
            .accessibilityLabel("Markdown source")
    }
}
