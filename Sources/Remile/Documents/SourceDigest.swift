import Foundation
import CryptoKit

/// One source fingerprint format for editing, review archives and automation.
enum SourceDigest {
    private static let digits = Array("0123456789abcdef".utf8)
    static func sha256(_ source: String) -> String {
        hex(SHA256.hash(data: Data(source.utf8)))
    }

    static func cancellableSHA256(_ data: Data) throws -> SHA256.Digest {
        let chunkSize = 1024 * 1024
        var hash = SHA256()
        for start in stride(from: data.startIndex, to: data.endIndex, by: chunkSize) {
            try Task.checkCancellation()
            hash.update(data: data[start..<min(start + chunkSize, data.endIndex)])
        }
        try Task.checkCancellation()
        return hash.finalize()
    }

    static func hex(_ hash: SHA256.Digest) -> String {
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in hash { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
