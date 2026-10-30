import XCTest
@testable import Remile

private final class ZoteroRecoveryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static func reset() { lock.lock(); requests = 0; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let attempt = Self.requests; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: attempt == 1 ? 403 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ZoteroConnectionTests: XCTestCase {
    @MainActor func testReturningFromSettingsRecoversFailedLibraryLoadWithoutPolling() async throws {
        let previous = UserDefaults.standard.object(forKey: ZoteroAccess.enabledKey)
        UserDefaults.standard.set(true, forKey: ZoteroAccess.enabledKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ZoteroAccess.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: ZoteroAccess.enabledKey) }
        }
        ZoteroRecoveryProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZoteroRecoveryProtocol.self]
        let session = URLSession(configuration: config)
        let model = ZoteroExtensionModel(client: ZoteroLocalClient(session: session))
        func settled() async throws {
            for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy)
        }
        model.refresh()
        try await settled()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.libraries.isEmpty)
        model.resumeConnection()
        model.resumeConnection()
        try await settled()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.libraries.map(\.id), ["users/0"])
        XCTAssertEqual(ZoteroRecoveryProtocol.count, 3)
        model.resumeConnection()
        XCTAssertFalse(model.busy)
        XCTAssertEqual(ZoteroRecoveryProtocol.count, 3)
    }
}
