import Foundation
import CryptoKit

/// One source fingerprint format for editing, review archives and automation.
enum SourceDigest {
    private static let digits = Array("0123456789abcdef".utf8)
    static func sha256(_ source: String) -> String {
        let hash = SHA256.hash(data: Data(source.utf8))
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in hash { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
