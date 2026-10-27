import SwiftUI

struct MarkdownTableEditor: View {
    @ObservedObject var state: State
    let apply: (MarkdownTable) -> Bool
    let close: () -> Void
    final class State: ObservableObject {
        @Published var table: MarkdownTable
        @Published var error: String?
        let source: String
        init(table: MarkdownTable, source: String) { self.table = table; self.source = source }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Table").font(RemileType.heading)
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 5) {
                    ForEach(state.table.cells.indices, id: \.self) { row in
                        HStack(spacing: 5) {
                            ForEach(0..<state.table.columns, id: \.self) { column in
                                TextField(row == 0 ? "Heading" : "", text: Binding(get: { state.table.cells.indices.contains(row) && state.table.cells[row].indices.contains(column) ? state.table.cells[row][column] : "" }, set: { if state.table.cells.indices.contains(row), state.table.cells[row].indices.contains(column) { state.table.cells[row][column] = $0 } })).textFieldStyle(.roundedBorder).frame(width: 140)
                            }
                            Button { state.table.cells.remove(at: row) } label: { SymbolIcon(systemName: "minus.circle") }.disabled(state.table.cells.count <= 2 || row == 0).remileHelp("Remove row")
                        }
                    }
                }.padding(2)
            }.frame(maxHeight: 320)
            HStack {
                Button("Add row") { state.table.cells.append(Array(repeating: "", count: state.table.columns)) }.disabled(state.table.cells.count >= 100)
                Button("Add column") { for row in state.table.cells.indices { state.table.cells[row].append("") } }.disabled(state.table.columns >= 12)
                Button("Remove last column") { for row in state.table.cells.indices { state.table.cells[row].removeLast() } }.disabled(state.table.columns <= 1)
            }
            if let error = state.error { Text(error).font(RemileType.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel", action: close).keyboardShortcut(.cancelAction); Button("Apply") { if apply(state.table) { close() } else { state.error = "The source changed. Close this table and open it again." } }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 600).background(RemileStyle.background)
    }
}
