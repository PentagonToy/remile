import SwiftUI

struct ReferenceSettings: View {
    @AppStorage(ReferenceKeyRule.preference) private var rule = ReferenceKeyRule.surnameYearWord.rawValue
    @AppStorage(ReferenceColumnWidths.preference) private var columnWidths = "{}"
    @AppStorage(ReferenceColumn.preference) private var columns = ReferenceColumn.defaults
    @AppStorage(ReferenceExport.abstractPreference) private var abstract = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reference settings").font(RemileType.heading)
                Text("Citation keys").font(RemileType.section)
                Picker("Format", selection: $rule) { ForEach(ReferenceKeyRule.allCases, id: \.self) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                Text((ReferenceKeyRule(rawValue: rule) ?? .surnameYearWord).example)
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(RemileStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .remileHelp("Uses the first author or editor's surname. Existing keys change only when regenerated.")
                Text("Existing keys stay unchanged.").font(RemileType.caption).foregroundStyle(.secondary)
                Divider()
                HStack { Text("List columns").font(RemileType.section); Spacer(); Button("Reset widths") { columnWidths = "{}" }.buttonStyle(RemileActionStyle()) }
                ForEach(ReferenceColumn.allCases) { column in
                    Toggle(column.label, isOn: Binding(get: { ReferenceColumn.visible(columns).contains(column) }, set: { enabled in
                        var selected = Set(ReferenceColumn.visible(columns)); if enabled { selected.insert(column) } else { selected.remove(column) }
                        columns = ReferenceColumn.allCases.filter { selected.contains($0) }.map(\.rawValue).joined(separator: ",")
                    })).disabled(column == .title)
                }
                Divider()
                Toggle("Include abstract in BibTeX", isOn: $abstract)
                Text("Applies to copies and exports. Imported abstracts stay stored.").font(RemileType.caption).foregroundStyle(.secondary)
            }.padding(20).scrollContentGutter()
        }.font(RemileType.control).toggleStyle(.checkbox).frame(width: 360, height: 570).background(RemileStyle.background).tint(RemileStyle.accent)
    }
}
