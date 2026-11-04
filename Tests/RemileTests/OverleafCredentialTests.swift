import Security
import XCTest
@testable import Remile

final class OverleafCredentialTests: XCTestCase {
    func testSilentReadRecoversWhenTokenBecomesAvailable() throws {
        let id = UUID()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OverleafCredential.service,
            kSecAttrAccount as String: id.uuidString,
        ]
        defer { try? OverleafCredential.erase(id) }

        XCTAssertThrowsError(try OverleafCredential.read(id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No Git token is saved"))
        }
        // Write directly to Keychain so the next read cannot use the in-memory token cache.
        let token = "synthetic-overleaf-test-token"
        XCTAssertEqual(KeychainAccess.store(Data(token.utf8), matching: query, attributes: [:]), errSecSuccess)
        XCTAssertEqual(try OverleafCredential.read(id), token)
    }
}
