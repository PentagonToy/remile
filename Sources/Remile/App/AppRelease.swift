import Foundation

struct RemileVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let beta: Int?
    init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let sections = raw.components(separatedBy: "-beta.")
        guard sections.count <= 2 else { return nil }
        if sections.count == 2 {
            let number = sections[1]
            guard !number.isEmpty, number.first != "0", number.allSatisfy(\.isNumber), let value = Int(number), value > 0 else { return nil }
            beta = value
        } else { beta = nil }
        let fields = sections[0].split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || $0.first != "0") }), fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    var description: String { parts.map(String.init).joined(separator: ".") + (beta.map { "-beta.\($0)" } ?? "") }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        if let a = lhs.beta, let b = rhs.beta { return a < b }
        return lhs.beta != nil && rhs.beta == nil
    }
}

struct RemileRelease {
    let version: RemileVersion
    let download: URL
    static let current = Bundle.main.object(forInfoDictionaryKey: "RemileDisplayVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.3"
    static let page = URL(string: "https://github.com/PentagonToy/remile/releases")!
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x86_64"
    #endif
    private struct Record: Decodable {
        let tag_name: String, draft: Bool, prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String, state: String, browser_download_url: String }
    }
    static func newest(_ data: Data, after current: RemileVersion, architecture: String = architecture) throws -> Self? {
        try JSONDecoder().decode([Record].self, from: data).compactMap { release -> Self? in
            guard !release.draft, !release.prerelease, let version = RemileVersion(release.tag_name), version.beta == nil, version > current else { return nil }
            let name = "remile-\(version)-\(architecture).dmg"
            let address = "https://github.com/PentagonToy/remile/releases/download/\(release.tag_name)/\(name)"
            guard release.assets.contains(where: { $0.name == name && $0.state == "uploaded" && $0.browser_download_url == address }), let url = URL(string: address) else { return nil }
            return Self(version: version, download: url)
        }.max { $0.version < $1.version }
    }
}
