import SwiftUI

struct RemarkableCloudRow: Identifiable {
    let item: RemarkableCloudItem
    let depth: Int
    let path: String
    var id: String { item.id }
}

enum RemarkableCloudTree {
    static func rows(_ items: [RemarkableCloudItem], expanded: Set<String>, query: String) -> [RemarkableCloudRow] {
        var byID: [String: RemarkableCloudItem] = [:]
        for item in items where byID[item.id] == nil { byID[item.id] = item }
        var children: [String: [RemarkableCloudItem]] = [:]
        for item in byID.values {
            let parent = item.parentID.flatMap { byID[$0]?.isFolder == true && $0 != item.id ? $0 : nil } ?? ""
            children[parent, default: []].append(item)
        }
        for key in Array(children.keys) {
            children[key]?.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
        var all: [RemarkableCloudRow] = []
        var seen = Set<String>()
        func appendTree(_ root: RemarkableCloudItem) {
            var pending = [RemarkableCloudRow(item: root, depth: 0, path: "My files")]
            while let row = pending.popLast() {
                guard seen.insert(row.id).inserted else { continue }
                all.append(row)
                let path = row.path + " / " + row.item.title
                for child in (children[row.id] ?? []).reversed() {
                    pending.append(RemarkableCloudRow(item: child, depth: row.depth + 1, path: path))
                }
            }
        }
        for item in children[""] ?? [] { appendTree(item) }
        // Keep malformed or cyclic cloud entries reachable without recursive traversal.
        for item in items where !seen.contains(item.id) { appendTree(item) }
        return visibleRows(all, expanded: expanded, query: query)
    }
    static func visibleRows(_ all: [RemarkableCloudRow], expanded: Set<String>, query: String) -> [RemarkableCloudRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            var matches = Set(all.filter {
                $0.item.title.localizedCaseInsensitiveContains(term) || $0.path.localizedCaseInsensitiveContains(term)
            }.map(\.id))
            for row in all.reversed() where matches.contains(row.id) {
                if let parent = row.item.parentID { matches.insert(parent) }
            }
            return all.filter { matches.contains($0.id) }
        }
        var hiddenDepth: Int?
        return all.filter { row in
            if let depth = hiddenDepth, row.depth > depth { return false }
            hiddenDepth = row.item.isFolder && !expanded.contains(row.id) ? row.depth : nil
            return true
        }
    }
}

struct RemarkableFolderPicker: View {
    let items: [RemarkableCloudItem]
    let query: String
    let busy: Bool
    @Binding var selection: Set<String>
    @State private var expanded = Set<String>()
    var body: some View {
        let folders = items.filter(\.isFolder)
        let all = RemarkableCloudTree.rows(folders, expanded: Set(folders.map(\.id)), query: "")
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = RemarkableCloudTree.visibleRows(all, expanded: expanded, query: term)
        let parents = Dictionary(folders.map { ($0.id, $0.parentID ?? "") }, uniquingKeysWith: { first, _ in first })
        let states = folderStates(all, parents: parents)
        let branches = Set(folders.compactMap(\.parentID))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if term.isEmpty || "Unfiled".localizedCaseInsensitiveContains(term) {
                    HStack(spacing: RemileControl.spacing) {
                        checkbox(RemarkableFolderScope.unfiledID, title: "Unfiled", state: selection.contains(RemarkableFolderScope.unfiledID) ? .on : .off, inherited: false)
                        Color.clear.frame(width: RemileControl.iconSlot, height: RemileControl.iconSlot)
                        Button { change(RemarkableFolderScope.unfiledID, chosen: !selection.contains(RemarkableFolderScope.unfiledID)) } label: {
                            SymbolLabel("Unfiled", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy)
                    }.padding(.vertical, RemileControl.spacing / 2).padding(.horizontal, RemileControl.spacing)
                }
                ForEach(rows) { row in
                    HStack(spacing: RemileControl.spacing) {
                        let state = states[row.id] ?? .off
                        checkbox(row.id, title: row.item.title, state: state, inherited: state == .on && !selection.contains(row.id))
                        Button {
                            if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                        } label: {
                            SymbolIcon(systemName: !term.isEmpty || expanded.contains(row.id) ? "chevron.down" : "chevron.right").opacity(branches.contains(row.id) ? 1 : 0)
                        }.buttonStyle(.plain).disabled(busy || !term.isEmpty || !branches.contains(row.id))
                            .accessibilityLabel("Folders in " + row.item.title)
                        Button { change(row.id, chosen: state != .on) } label: {
                            SymbolLabel(row.item.title, systemImage: "folder").lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy || (state == .on && !selection.contains(row.id)))
                    }.padding(.leading, CGFloat(min(row.depth, 8)) * RemileControl.rowSpacing)
                        .padding(.vertical, RemileControl.spacing / 2).padding(.horizontal, RemileControl.spacing)
                        .remileHelp(row.path + " / " + row.item.title)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).scrollContentGutter()
        }.frame(height: 420)
    }
    private func checkbox(_ id: String, title: String, state: NSControl.StateValue, inherited: Bool) -> some View {
        SourceFolderCheckbox(state: state, label: title, enabled: !busy && !inherited) { chosen in
            change(id, chosen: chosen)
        }.frame(width: RemileControl.height, height: RemileControl.height)
    }
    private func change(_ id: String, chosen: Bool) {
        if chosen {
            selection.insert(id)
            selection = RemarkableFolderSelection.canonical(selection, items: items)
        } else { selection.remove(id) }
    }
    private func folderStates(_ rows: [RemarkableCloudRow], parents: [String: String]) -> [String: NSControl.StateValue] {
        var states: [String: NSControl.StateValue] = [:]
        for row in rows {
            if selection.contains(row.id) || parents[row.id].map({ states[$0] == .on }) == true { states[row.id] = .on }
        }
        for id in selection {
            var parent = parents[id], seen: Set<String> = [id]
            while let value = parent, seen.insert(value).inserted {
                if states[value] != .on { states[value] = .mixed }
                parent = parents[value]
            }
        }
        return states
    }
}
