import Foundation

/// An explicit allowlist keeps account data, file locations and credentials out of portable settings.
enum PortableSettings {
    enum Value: Codable, Equatable {
        case string(String), bool(Bool), number(Double)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
            else { self = .string(try value.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); switch self { case .string(let text): try value.encode(text); case .bool(let bool): try value.encode(bool); case .number(let number): try value.encode(number) } }
        var object: Any { switch self { case .string(let value): value; case .bool(let value): value; case .number(let value): value } }
    }
    struct Snapshot: Codable { var format = 1; var application = "remile"; var preferences: [String: Value] }
    static let defaults: [String: Value] = [
        "reader.appearance": .string("System"), "appearance.animations": .bool(true), "editor.sidebarArtwork": .bool(true),
        "reader.markdownZoom": .number(100), "pdf.defaultPaperSize": .string("A4"), "pdf.defaultLandscape": .bool(false),
        "markdown.fontSize": .number(18), "markdown.spellcheck": .bool(true), "markdown.lineNumbers": .bool(false),
        "latex.fontSize": .number(17), "latex.theme": .string("remile."), "latex.engine": .string("Automatic"), "latex.bibliography": .bool(true), "latex.compileTimeLimit": .number(180), "latex.historyMinutes": .number(3),
        "editor.language": .string("Automatic"), "editor.spellcheck": .bool(true), "editor.focusMode": .bool(false), "editor.showExternalEdits": .bool(false), "editor.toolSounds": .bool(true),
        "reader.elasticScrolling": .bool(true), "reader.markdownSerif": .bool(false), "markdown.autoPair": .bool(true), "markdown.livePreview": .bool(true),
        "search.includeBibliography": .bool(false), "search.boosting": .bool(true), "search.spellingSuggestions": .bool(true),
        ReferenceKeyRule.preference: .string(ReferenceKeyRule.surnameYearWord.rawValue), ReferenceColumn.preference: .string(ReferenceColumn.defaults), ReferenceColumnWidths.preference: .string("{}"), ReferenceExport.abstractPreference: .bool(false)
    ]
    static func snapshot(_ store: UserDefaults = .standard) -> Snapshot {
        var result = defaults
        for (key, fallback) in defaults {
            guard let object = store.object(forKey: key) else { continue }
            switch fallback { case .string: if let string = object as? String { result[key] = .string(string) }; case .bool: result[key] = .bool(store.bool(forKey: key)); case .number: result[key] = .number(store.double(forKey: key)) }
        }
        for name in WorkspaceLayout.paneNames { let key = WorkspaceLayout.key(name); let width = store.double(forKey: key); if width.isFinite, width >= 20, width <= 5000 { result[key] = .number(width) } }
        return Snapshot(preferences: result)
    }
    static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.format == 1, snapshot.application == "remile", snapshot.preferences.count <= 60 else { throw Failure("Choose a supported remile preset.") }
        for (key, value) in snapshot.preferences {
            if let fallback = defaults[key] {
                switch (fallback, value) {
                case (.bool, .bool): break
                case (.number, .number(let number)) where number.isFinite && number >= 0 && number <= 5000: break
                case (.string, .string(let text)) where text.count <= 2000: break
                default: throw Failure("This preset contains an invalid value.")
                }
            } else if WorkspaceLayout.paneNames.contains(where: { WorkspaceLayout.key($0) == key }), case .number(let width) = value, width.isFinite, (20...5000).contains(width) { }
            else { throw Failure("This preset contains unsupported preferences.") }
        }
        if case .string(let rule) = snapshot.preferences[ReferenceKeyRule.preference], !ReferenceKeyRule.allCases.contains(where: { $0.rawValue == rule }) { throw Failure("Choose a supported citation key format.") }
        if case .string(let appearance) = snapshot.preferences["reader.appearance"], !["System", "Light", "Dark"].contains(appearance) { throw Failure("Choose a supported theme.") }
        if case .number(let size) = snapshot.preferences["markdown.fontSize"], !(11...40).contains(size) { throw Failure("Choose a readable Markdown font size.") }
        if case .number(let size) = snapshot.preferences["latex.fontSize"], !(11...40).contains(size) { throw Failure("Choose a readable LaTeX font size.") }
        if case .string(let columns) = snapshot.preferences[ReferenceColumn.preference], !Set(columns.split(separator: ",").map(String.init)).isSubset(of: Set(ReferenceColumn.allCases.map(\.rawValue))) { throw Failure("Choose supported reference columns.") }
    }
    static func apply(_ snapshot: Snapshot, to store: UserDefaults = .standard) throws {
        try validate(snapshot)
        for (key, value) in snapshot.preferences { store.set(value.object, forKey: key) }
        if snapshot.preferences[ReferenceColumn.preference] != nil { store.set(true, forKey: "reference.columns.typeDefault") }
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
}
