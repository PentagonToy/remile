import Foundation

enum RemarkableCitationKey {
    static func note(title: String, created: Date) -> String {
        let name = (title as NSString).deletingPathExtension
        let first = name.components(separatedBy: "_").first ?? name
        let chosen = first.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 ? first : name
        let latin = (chosen.applyingTransform(.toLatin, reverse: false) ?? chosen)
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = latin.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let ascii = slug.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: created)
        let date = String(format: "%04d%02d%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
        return "note_" + (ascii.isEmpty ? "Untitled" : String(ascii.prefix(40))) + "_" + date
    }
}
