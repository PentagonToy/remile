import Foundation

struct WriterPageStyle: Codable, Equatable {
    var header = ""
    var footer = ""
    var topLine = false
    var bottomLine = false
    var pageNumbers = false
    var columns: Int?
    var columnCount: Int { columns ?? 1 }
    var valid: Bool { (1...2).contains(columnCount) && header.count <= 200 && footer.count <= 200 && header.rangeOfCharacter(from: .newlines) == nil && footer.rangeOfCharacter(from: .newlines) == nil }
}
