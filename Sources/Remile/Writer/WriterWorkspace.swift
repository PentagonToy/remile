import SwiftUI
import AppKit

struct WriterWorkspace: View {
    @ObservedObject var model: WriterModel
    let goHome: () -> Void
    @StateObject private var state = Presentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class Presentation: ObservableObject {
        @Published var formula = false
        @Published var latex = ""
        @Published var tools = true
        @Published var colours = false
        @Published var settings = false
        @Published var shapes = false
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: goHome) { Image(systemName: "chevron.left") }.buttonStyle(RemileToolStyle()).remileHelp("Back to Home").accessibilityLabel("Back to Home")
                Text("Writer").font(RemileType.heading)
                Divider().frame(height: 18)
                Button { state.tools.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).remileHelp("Show or hide writing tools").accessibilityLabel("Writing tools")
                HStack(spacing: 8) {
                    Button { model.undo.undo(); model.revisionChanged() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.undo.canUndo).accessibilityLabel("Undo").remileHelp("Undo")
                    Button { model.undo.redo(); model.revisionChanged() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!model.undo.canRedo).accessibilityLabel("Redo").remileHelp("Redo")
                }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).padding(.leading, 4)

                Spacer()
                Text(model.title + (model.dirty ? " · Edited" : "")).font(RemileType.callout.weight(.semibold)).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 5).frame(maxWidth: 360).background(RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                Spacer()
                Button { model.open() } label: { Image(systemName: "folder") }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).remileHelp("Open a DOCX document").accessibilityLabel("Open document")
                Button { model.save() } label: { DocumentActionIcon(action: .save) }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).accessibilityLabel("Save").remileHelp("Save changes · ⌘S")
                    .contextMenu { Button("Save As…") { model.saveAs() } }
                Button { model.exportCopy() } label: { DocumentActionIcon(action: .export) }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).accessibilityLabel("Export").remileHelp("Create a separate PDF or DOCX copy.")
            }.font(RemileType.control).padding(.horizontal, 12).padding(.vertical, 5).background(RemileStyle.background)
            Divider()
            GeometryReader { geometry in
                ReaderSplit(isPresented: state.tools, initial: min(320, max(250, geometry.size.width * 0.22)), minimum: 250, maximum: 340, minimumContent: 380, label: "writer tools", pane: { tools }, content: { document })
            }
            HStack {
                Text("\(model.pages) \(model.pages == 1 ? "page" : "pages")"); Spacer()
                if model.loading { ProgressView().controlSize(.mini); Text("Opening…") }
                if model.rendering { ProgressView().controlSize(.mini); Text("Setting the equation…") }
                if let error = model.error { Text(error).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message") }
                ReaderThemeButton()
            }.font(RemileType.caption).padding(.horizontal, 12).frame(minHeight: 32).background(RemileStyle.editorBar)
        }.font(RemileType.control).background(RemileStyle.background).tint(RemileStyle.accent)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.tools)
            .sheet(isPresented: $state.formula) { formula }
    }
    private func formatting<Value>(_ key: ReferenceWritableKeyPath<WriterModel, Value>) -> Binding<Value> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0; model.format() })
    }
    private var tools: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.settings {
                        HStack {
                            Button { state.settings = false } label: { Image(systemName: "chevron.left") }.buttonStyle(RemileToolStyle()).accessibilityLabel("Back to formatting").remileHelp("Back to formatting")
                            Text("Page").font(RemileType.caption.weight(.semibold))
                            Spacer()
                        }
                        Divider()
                        WriterPageControls(model: model)
                    } else {
                        formatTools
                        Divider()
                        insertTools
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14).padding(.trailing, 28).padding(.vertical, 14)
            }.scrollBounceBehavior(.basedOnSize)
            Divider()
            EditorSidebarFooter(compact: true, title: "Settings") { state.settings.toggle() }

        }.font(RemileType.control).controlSize(.regular).foregroundStyle(RemileStyle.ink).background(RemileStyle.sidebar)
    }
    private var selectionTitle: String {
        switch model.selectedObject?.kind {
        case .line: "Line"
        case .rectangle: "Text box"
        case .table: "Table"
        case .image: "Image"
        case nil: "Text"
        }
    }
    @ViewBuilder private var formatTools: some View {
        HStack {
            Text(selectionTitle).font(RemileType.caption.weight(.semibold))
            Spacer()
            if model.selectedObject != nil {
                Button(role: .destructive) { model.deleteShape() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).accessibilityLabel("Delete object").remileHelp("Delete object")
            }
        }
        Divider()
        if let object = model.selectedObject {
            if object.kind == .image {
                Label("Move freely on the page.", systemImage: "move.3d")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Drag a corner to resize.").font(RemileType.caption).foregroundStyle(.secondary)
            } else {
                if object.kind == .table {
                    VStack(spacing: 12) {
                        Stepper("Rows: \(object.rows)", value: Binding(get: { object.rows }, set: { model.resizeTable(rows: $0, columns: object.columns) }), in: 1...12)
                        Stepper("Columns: \(object.columns)", value: Binding(get: { object.columns }, set: { model.resizeTable(rows: object.rows, columns: $0) }), in: 1...12)
                    }
                }
                if object.kind != .line { section("Text"); typography; colourTools; section("Paragraph"); paragraphTools; Divider() }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(object.kind == .table ? "Border" : "Stroke"); Spacer(); Stepper(value: formatting(\.lineWidth), in: 0.5...6, step: 0.5) { Text(String(format: "%g pt", model.lineWidth)).monospacedDigit() } }
                    if object.kind == .line {
                        Picker("Start", selection: formatting(\.startArrow)) { ForEach(WriterObject.Arrow.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("End", selection: formatting(\.endArrow)) { ForEach(WriterObject.Arrow.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    } else if object.kind == .rectangle { Toggle("Fill", isOn: formatting(\.fill))
                        if model.fill {
                            ColorPicker("Fill colour", selection: Binding(get: { Color(nsColor: WriterPalette.colour(model.fillColour).withAlphaComponent(model.fillOpacity)) }, set: { let colour = NSColor($0); model.fillColour = WriterPalette.hex(colour); model.fillOpacity = colour.alphaComponent; model.format() }), supportsOpacity: true)
                        } }
                }
                if object.kind == .line { colourTools }
                if object.kind != .line {
                    Text(object.kind == .table ? "Double-click a cell to write." : "Double-click to write inside.")
                        .font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            objectLayout
        } else { typography; colourTools; section("Paragraph"); paragraphTools }
    }
    private var objectLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Toggle("Text wrap", isOn: Binding(get: { model.selectedObject?.wrapsText == true }, set: { value in
                if var item = model.selectedObject { item.wrapsText = value; model.update(item) }
            }))
            Toggle("Lock position", isOn: Binding(get: { model.selectedObject?.locked == true }, set: { value in
                if var item = model.selectedObject { item.locked = value; model.update(item) }
            }))
        }
    }
    private var typography: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                optionPicker(WriterOptions.fonts, selected: model.font.rawValue, label: "Font") { value in
                    guard let font = WriterFont(rawValue: value) else { return }
                    model.font = font; model.format()
                }
                HStack(spacing: 2) {
                    TextField("Font size", value: Binding(get: { model.size }, set: { model.size = min(72, max(6, $0)); model.format() }), format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 34).accessibilityLabel("Font size in points")
                    Stepper("Font size", value: formatting(\.size), in: 6...72).labelsHidden().fixedSize()
                }.padding(.horizontal, 6).frame(height: 28).background(RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            }
            HStack(spacing: 4) {
                traitButton("Bold", icon: "bold", active: model.bold) { model.bold.toggle(); model.format() }
                traitButton("Italic", icon: "italic", active: model.italic) { model.italic.toggle(); model.format() }
            }
        }
    }
    private var paragraphTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    alignButton(.left, icon: "text.alignleft", title: "Align left")
                    alignButton(.center, icon: "text.aligncenter", title: "Centre")
                    alignButton(.right, icon: "text.alignright", title: "Align right")
                    alignButton(.justified, icon: "text.justify", title: "Justify")
                }
            }
            if model.selectedObject == nil {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.and.down.text.horizontal").frame(width: 20).accessibilityLabel("Line spacing").remileHelp("Line spacing")
                    optionPicker(WriterOptions.spacing, selected: String(format: "%g", model.leading), label: "Line spacing") { value in
                        guard let spacing = Double(value) else { return }
                        model.leading = spacing; model.format()
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet").frame(width: 20).accessibilityHidden(true)
                    optionPicker(WriterOptions.lists, selected: model.list.rawValue, label: "List style") { value in
                        if let style = WriterList(rawValue: value) { model.applyList(style) }
                    }
                }
            }
        }
    }
    private func optionPicker(_ options: [RemileOption], selected: String, label: String, select: @escaping (String) -> Void) -> some View {
        RemileOptionPicker(options: options, selected: selected, label: label, select: select)
            .padding(.horizontal, 5).frame(height: 28)
            .background(RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
    }
    private func traitButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity).frame(height: 28)
                .background(active ? RemileStyle.accent.opacity(0.20) : RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                .foregroundStyle(active ? RemileStyle.accent : RemileStyle.ink)
                .contentShape(Rectangle())
        }.buttonStyle(RemileCompactToolStyle()).accessibilityLabel(title).accessibilityAddTraits(active ? .isSelected : []).remileHelp(title)
    }
    private func alignButton(_ value: NSTextAlignment, icon: String, title: String) -> some View {
        traitButton(title, icon: icon, active: model.alignment == value.rawValue) { model.alignment = value.rawValue; model.format() }
    }
    private var colourTools: some View {
        DisclosureGroup(isExpanded: $state.colours) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Palette", selection: $model.palette) { ForEach(WriterPalette.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 12) {
                    ForEach(model.palette.colours, id: \.self) { hex in
                        Button { model.colour = hex; model.format() } label: {
                            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: WriterPalette.colour(hex))).frame(width: 21, height: 21)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.colour == hex ? RemileStyle.accent : Color.gray.opacity(0.4), lineWidth: model.colour == hex ? 2.5 : 0.5))
                        }.buttonStyle(.plain).accessibilityLabel(String(format: "Colour #%06X", hex)).remileHelp(String(format: "#%06X", hex))
                    }
                }
                ColorPicker("Custom", selection: Binding(get: { Color(nsColor: WriterPalette.colour(model.colour)) }, set: { model.colour = WriterPalette.hex(NSColor($0)); model.format() }), supportsOpacity: false)
            }.padding(.top, 14)
        } label: {
            HStack { Text("Colour"); Spacer(); RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: WriterPalette.colour(model.colour))).frame(width: 18, height: 18).overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4), lineWidth: 0.5)) }
        }
    }
    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Divider(); Text(title).font(RemileType.caption.weight(.semibold)) }
    }
    private var insertTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert").font(RemileType.caption.weight(.semibold))
            HStack(spacing: 8) {
                traitButton("Shapes", icon: "square.on.circle", active: state.shapes) { state.shapes.toggle() }
                    .popover(isPresented: $state.shapes) {
                        VStack(alignment: .leading, spacing: 4) {
                            shapeChoice("Line", icon: "line.diagonal") { model.add(.line) }
                            shapeChoice("Rectangle", icon: "rectangle") { model.add(.rectangle) }
                        }.padding(10).frame(width: 170)
                    }
                traitButton("LaTeX", icon: "function", active: state.formula) { state.formula = true }.disabled(model.rendering)
                traitButton("Image", icon: "photo", active: false) { model.chooseImage() }
                traitButton("Table", icon: "tablecells", active: false) { model.add(.table) }
            }
        }
    }
    private func shapeChoice(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { state.shapes = false; action() } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(RemileToolStyle())
    }
    private var document: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WriterColumns(model: model, compact: true)
                Spacer()
                Button { model.setZoom(model.zoom - 0.1) } label: { Image(systemName: "minus") }.disabled(model.zoom <= 0.25).accessibilityLabel("Zoom out")
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in Button("\(Int(value * 100))%") { model.setZoom(value) } }
                } label: { Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit() }.fixedSize().remileHelp("Zoom")
                Button { model.setZoom(model.zoom + 0.1) } label: { Image(systemName: "plus") }.disabled(model.zoom >= 2).accessibilityLabel("Zoom in")
                Button("Fit") { model.fitWidth() }.remileHelp("Fit page width")
            }.buttonStyle(RemileCompactToolStyle()).font(RemileType.small).padding(.horizontal, 10).frame(height: 34).background(RemileStyle.editorBar)
            Divider()
            WriterSurface(model: model).allowsHitTesting(!model.loading)
        }
    }
    private var formula: some View {
        WriterLaTeXSheet(source: $state.latex, cancel: { state.formula = false }) { source in
            state.formula = false
            Task { await model.insertFormula(source) }
        }
    }
}
