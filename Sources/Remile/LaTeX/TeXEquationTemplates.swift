import Foundation

struct TeXEquationTemplate: Codable {
    let name: String
    let source: String

    private static let key = "latex.equationTemplates"
    static func read() -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: key), data.count <= 256_000 else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    static func save(name: String, source: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80, !name.contains(where: \.isNewline),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 4_096 else { return false }
        var templates = read()
        templates.removeAll { $0.name == name }
        guard templates.count < 40 else { return false }
        templates.append(Self(name: name, source: source))
        guard let data = try? JSONEncoder().encode(templates), data.count <= 256_000 else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    static func remove(name: String) {
        guard let data = try? JSONEncoder().encode(read().filter { $0.name != name }) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
