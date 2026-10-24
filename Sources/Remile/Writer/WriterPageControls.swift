import SwiftUI

struct WriterPageControls: View {
    @ObservedObject var model: WriterModel
    private func value<T>(_ key: WritableKeyPath<WriterPageStyle, T>) -> Binding<T> {
        Binding(get: { model.pageStyle[keyPath: key] }, set: { var style = model.pageStyle; style[keyPath: key] = $0; model.setPageStyle(style) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paper").font(RemileType.caption.weight(.semibold))
            RemileOptionPicker(options: PaperSize.allCases.map { RemileOption(id: $0.rawValue, title: $0.rawValue) }, selected: model.paper, label: "Paper size") {
                model.resizePaper($0, landscape: model.landscape)
            }.padding(.horizontal, 5).frame(height: 28).background(RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            Picker("Orientation", selection: Binding(get: { model.landscape }, set: { model.resizePaper(model.paper, landscape: $0) })) {
                Text("Portrait").tag(false); Text("Landscape").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            Text("Columns").font(RemileType.caption.weight(.semibold))
            WriterColumns(model: model)
            Divider()
            Text("Header & footer").font(RemileType.caption.weight(.semibold))
            TextField("Header", text: value(\.header)).textFieldStyle(.roundedBorder)
            TextField("Footer", text: value(\.footer)).textFieldStyle(.roundedBorder)
            Toggle("Top line", isOn: value(\.topLine))
            Toggle("Bottom line", isOn: value(\.bottomLine))
            Toggle("Page numbers", isOn: value(\.pageNumbers))
            Divider()
            Toggle("Rulers", isOn: $model.showRulers)
        }.font(RemileType.caption).tint(RemileStyle.accent)
    }
}
