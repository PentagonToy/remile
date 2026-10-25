import Foundation

enum ReferenceKeyRule: String, Codable, CaseIterable, Sendable {
    case surnameYearWord, surnameYearTwoWords, surnameYear
    static let preference = "reference.keyRule"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: preference) ?? "") ?? .surnameYearWord }
    var label: String {
        switch self {
        case .surnameYearWord: return "Surname · Year · Title"
        case .surnameYearTwoWords: return "Surname · Year · Two title words"
        case .surnameYear: return "Surname · Year"
        }
    }
    var example: String {
        var reference = ReferenceRecord()
        reference.fields = ["author": "Toy, Pentagon", "year": "2026", "title": "Filter Methods"]
        return key(for: reference)
    }
    func key(for record: ReferenceRecord) -> String {
        let author = ReferenceText.authors(record.contributors).first ?? ""
        let family = author.contains(",") ? author.components(separatedBy: ",")[0] : author.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let surname = Self.parts(family).joined()
        let year = Self.parts(record.year).joined()
        var components = [surname.isEmpty ? "Reference" : surname, year.isEmpty ? "nd" : year]
        if self != .surnameYear {
            let words = Self.parts(record.fields["title"] ?? "")
            components += words.prefix(self == .surnameYearTwoWords ? 2 : 1)
        }
        return String(components.joined(separator: "_").prefix(140))
    }
    private static func parts(_ source: String) -> [String] {
        let stripped = source.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "", options: .regularExpression)
        let latin = (stripped.applyingTransform(.toLatin, reverse: false) ?? stripped).folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return latin.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").inverted).filter { !$0.isEmpty }
    }
}
