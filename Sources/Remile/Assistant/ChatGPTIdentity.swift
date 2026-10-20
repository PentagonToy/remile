import Foundation
import CryptoKit
import Security
import LocalAuthentication

enum ChatGPTIdentity {
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
    static func base64(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ value: String) -> Data? {
        let value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure("Could not start a secure sign-in.") }
        return base64(Data(bytes))
    }
    /// Validate identity before committing a new account or replacing its credentials.
    static func verify(_ token: String, client: String, nonce: String?, keys: Data, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let payload = decode(parts[1]), let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com", let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (claims["aud"] as? String == client || (claims["aud"] as? [String])?.contains(client) == true),
              let subject = claims["sub"] as? String, !subject.isEmpty,
              nonce == nil || claims["nonce"] as? String == nonce,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30,
              let jwks = try JSONSerialization.jsonObject(with: keys) as? [String: Any], let rows = jwks["keys"] as? [[String: Any]],
              let row = rows.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = (row["n"] as? String).flatMap(decode), let e = (row["e"] as? String).flatMap(decode), let signature = decode(parts[2]) else { throw Failure("The sign-in identity could not be verified.") }
        let der = sequence(integer(n) + integer(e))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil), SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else { throw Failure("The sign-in signature could not be verified.") }
        if let azp = claims["azp"] as? String, azp != client { throw Failure("The sign-in was issued for another application.") }
        if let audiences = claims["aud"] as? [String], audiences.count > 1, claims["azp"] as? String != client { throw Failure("The sign-in’s authorised application could not be verified.") }
        return claims
    }
    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count, octets = [UInt8]()
        if length < 128 { return Data([tag, UInt8(length)]) + bytes }
        while length > 0 { octets.insert(UInt8(length & 255), at: 0); length >>= 8 }
        return Data([tag, 0x80 | UInt8(octets.count)] + octets) + bytes
    }
    private static func integer(_ data: Data) -> Data { var bytes = Array(data); while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }; if (bytes.first ?? 0) >= 128 { bytes.insert(0, at: 0) }; return der(2, Data(bytes)) }
    private static func sequence(_ bytes: Data) -> Data { der(0x30, bytes) }
}

enum ChatGPTVault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.remile.chatgpt", kSecAttrAccount as String: "account"]
    static func read(interactive: Bool = false) -> Data? {
        KeychainAccess.data(matching: query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }, interactive: interactive)
    }
    static func write(_ bytes: Data) throws {
        let value: [String: Any] = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
        guard result == errSecSuccess || (result == errSecDuplicateItem && SecItemUpdate(query as CFDictionary, value as CFDictionary) == errSecSuccess) else { throw ChatGPTIdentity.Failure("Could not save the ChatGPT connection in Keychain.") }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}
