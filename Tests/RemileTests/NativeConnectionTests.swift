import Foundation
import Security
import XCTest

@testable import Remile

@MainActor final class NativeConnectionTests: XCTestCase {
    private func check(
        _ condition: @autoclosure () throws -> Bool, _ message: String, file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        let passed = try condition()
        XCTAssertTrue(passed, message, file: file, line: line)
    }
    private func rejects(
        _ message: String, file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action(), message, file: file, line: line)
    }
    func testSignedIdentityValidation() throws {
        let privateKey = SecKeyCreateRandomKey(
            [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil)!
        let publicData = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let der = [UInt8](publicData)
        var offset = 0
        func value() -> Data {
            offset += 1
            var length = Int(der[offset])
            offset += 1
            if length & 128 != 0 {
                let digits = length & 127
                length = 0
                for _ in 0..<digits {
                    length = (length << 8) | Int(der[offset])
                    offset += 1
                }
            }
            let result = Data(der[offset..<(offset + length)])
            offset += length
            return result
        }
        _ = value()
        offset = der[1] & 128 == 0 ? 2 : 2 + Int(der[1] & 127)
        let n = value()
        let e = value()
        let keys = try JSONSerialization.data(withJSONObject: [
            "keys": [["kid": "fixture", "kty": "RSA", "n": ChatGPTIdentity.base64(n), "e": ChatGPTIdentity.base64(e)]]
        ])
        let claims: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": "fixture-user", "aud": "fixture-client",
            "exp": Date().timeIntervalSince1970 + 600, "nonce": "fixture-nonce",
        ]
        func token(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"])
            let prefix =
                ChatGPTIdentity.base64(header) + "."
                + ChatGPTIdentity.base64(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
            let signature =
                SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(prefix.utf8) as CFData, nil)!
                as Data
            return prefix + "." + ChatGPTIdentity.base64(signature)
        }
        let signed = try token(claims)
        try check(
            ChatGPTIdentity.verify(signed, client: "fixture-client", nonce: "fixture-nonce", keys: keys)["sub"]
                as? String == "fixture-user", "verify signed account")
        rejects("wrong audience") {
            _ = try ChatGPTIdentity.verify(signed, client: "other", nonce: "fixture-nonce", keys: keys)
        }
        rejects("wrong nonce") {
            _ = try ChatGPTIdentity.verify(signed, client: "fixture-client", nonce: "other", keys: keys)
        }
        rejects("expired identity") {
            _ = try ChatGPTIdentity.verify(
                signed, client: "fixture-client", nonce: "fixture-nonce", keys: keys,
                now: Date().addingTimeInterval(1000))
        }
        var wrongIssuer = claims
        wrongIssuer["iss"] = "https://attacker.invalid"
        rejects("wrong issuer") {
            _ = try ChatGPTIdentity.verify(
                token(wrongIssuer), client: "fixture-client", nonce: "fixture-nonce", keys: keys)
        }
        let pieces = signed.split(separator: ".")
        let tampered = String(pieces[0]) + "." + ChatGPTIdentity.base64(Data("{}".utf8)) + "." + String(pieces[2])
        rejects("tampered claims") {
            _ = try ChatGPTIdentity.verify(tampered, client: "fixture-client", nonce: "fixture-nonce", keys: keys)
        }
        var altered = claims
        altered["sub"] = "another-user"
        let invalidSignature =
            String(pieces[0]) + "." + ChatGPTIdentity.base64(try JSONSerialization.data(withJSONObject: altered)) + "."
            + String(pieces[2])
        rejects("reject valid-shaped claims with an invalid signature") {
            _ = try ChatGPTIdentity.verify(
                invalidSignature, client: "fixture-client", nonce: "fixture-nonce", keys: keys)
        }
        var audience = claims
        audience["aud"] = ["fixture-client", "another-client"]
        rejects("multiple audiences require the authorised party") {
            _ = try ChatGPTIdentity.verify(
                token(audience), client: "fixture-client", nonce: "fixture-nonce", keys: keys)
        }
    }
    func testCallbackAndStructuredFailures() throws {
        let limitedBody = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","param":"model"}}"#.utf8)
        let limited = ChatGPTRequestFailure(status: 429, body: limitedBody, requestID: "fixture-request")
        check(
            limited.code == "subscription_sharing_usage_limit_exceeded" && limited.parameter == "model"
                && limited.requestID == "fixture-request" && limited.body == limitedBody,
            "retain structured HTTP failure details")
        check(
            limited.errorDescription?.contains("ChatGPT usage allowance") == true, "show an actionable app-usage error")
        check(
            ChatGPTCallback.parse("/auth/callback?code=fixture&state=expected&client_id=issued", state: "expected")?[
                "client_id"] == "issued", "OAuth callback")
        for target in [
            "/auth/callback?code=a&state=wrong", "/auth/callback?state=expected&state=wrong&code=a",
            "/auth/callback?state=expected", "/other?state=expected&code=a",
        ] { check(ChatGPTCallback.parse(target, state: "expected") == nil, "reject unexpected callback") }
        var stream = ChatGPTStream()
        try stream.receive(#"data: {"type":"response.output_text.delta","delta":"Hello"}"#)
        rejects("partial stream") { _ = try stream.result() }
        try stream.receive(#"data: {"type":"response.completed"}"#)
        try check(stream.result() == "Hello", "completed stream")
        rejects("stream failure after partial output") {
            var failed = ChatGPTStream()
            try failed.receive(#"data: {"type":"response.incomplete"}"#)
        }
        do {
            var failed = ChatGPTStream()
            try failed.receive(
                #"data: {"type":"response.failed","response":{"id":"fixture-response","error":{"code":"subscription_sharing_usage_limit_exceeded","param":"model"}}}"#
            )
            XCTFail("streamed failure must retain its details")
        } catch let failure as ChatGPTRequestFailure {
            check(
                failure.code == "subscription_sharing_usage_limit_exceeded" && failure.parameter == "model"
                    && failure.requestID == "fixture-response", "retain nested stream failure details")
        }
    }
    func testExactEditsAndCollections() throws {
        let source = "Hello \\textbff{world}."
        let suggestion = try JSONSerialization.data(withJSONObject: [
            "before": "\\textbff", "after": "\\textbf", "reason": "Correct the command.",
        ])
        let edit = try ChatGPTEdit.parse(String(decoding: suggestion, as: UTF8.self), source: source)
        try check(edit.applying(to: source) == "Hello \\textbf{world}.", "apply a unique exact source edit")
        rejects("ambiguous suggestion") {
            _ = try ChatGPTEdit.parse(String(decoding: suggestion, as: UTF8.self), source: source + source)
        }
        rejects("stale source") { _ = try edit.applying(to: "changed") }
        let id = UUID()
        let other = UUID()
        let allowed = Set(["main.tex", "figure.pdf"])
        let groups = [
            TeXCollections.Group(id: id, name: "Writing", paths: ["main.tex"]),
            TeXCollections.Group(id: other, name: "Figures"),
        ]
        let moved = TeXCollections.assigning(["main.tex", "../secret"], to: other, groups: groups, allowed: allowed)
        check(
            moved[0].paths.isEmpty && moved[1].paths == ["main.tex"],
            "collections only assign known paths and keep files exclusive")
        check(
            TeXCollections.assigning(["main.tex"], to: nil, groups: moved, allowed: allowed).allSatisfy {
                $0.paths.isEmpty
            }, "remove virtual grouping")
        check(
            TeXCollections.assigning(["main.tex"], to: UUID(), groups: groups, allowed: allowed) == groups,
            "reject unknown collection")
        let encoded = try JSONEncoder().encode(moved)
        try check(JSONDecoder().decode([TeXCollections.Group].self, from: encoded) == moved, "persist visual grouping")
        let parentID = UUID()
        let childID = UUID()
        let nested = [
            TeXCollections.Group(id: parentID, name: "Parent"),
            TeXCollections.Group(id: childID, name: "Child", parent: parentID),
        ]
        check(TeXCollections.moving([parentID], under: childID, groups: nested) == nil, "reject collection cycles")
        check(
            TeXCollections.moving([childID], under: nil, groups: nested)?.last?.parent == nil,
            "move a nested collection to root")
        check(
            TeXCollections.moving([parentID, childID], under: nil, groups: nested)?.last?.parent == parentID,
            "bulk collection moves preserve nesting")
        check(
            TeXCollections.removing(parentID, groups: nested).first?.parent == nil,
            "removing a collection preserves its child")
    }
    func testCatalogueTagsAndUsage() throws {
        var countedStream = ChatGPTStream()
        try countedStream.receive(#"data: {"type":"response.output_text.delta","delta":"ok"}"#)
        try countedStream.receive(
            #"data: {"type":"response.completed","response":{"usage":{"input_tokens":31,"output_tokens":7}}}"#)
        check(countedStream.inputTokens == 31 && countedStream.outputTokens == 7, "read returned token usage")
        let listing = Data(
            #"{"projects":[{"_id":"6ad72e207e5cd74f01fe6b18","name":"Writing"},{"_id":"6ad72e207e5cd74f01fe6b18","name":"duplicate"}]}"#
                .utf8)
        try check(OverleafWebClient.parseProjects(listing).count == 1, "account project deduplication")
        rejects("malformed project id") {
            _ = try OverleafWebClient.parseProjects(Data(#"{"projects":[{"_id":"../private","name":"bad"}]}"#.utf8))
        }
        check(
            TeXFileSystem.reference("sections/introduction.tex") == "sections/introduction",
            "source references omit the TeX extension")
        check(
            TeXFileSystem.reference("figures/diagram.pdf") == "figures/diagram.pdf"
                && TeXFileSystem.reference("figures/photo.png") == "figures/photo.png",
            "image references preserve their extensions")
        check(
            TeXFileSystem.topLevel(["a", "a/b.tex", "c.tex"]) == ["a", "c.tex"],
            "bulk file moves do not move a child twice")

        let tagProject = "6ad72e207e5cd74f01fe6b18"
        let tagFixture = try JSONSerialization.data(withJSONObject: [
            ["_id": "tag-a", "name": "Research", "color": "#e88a33", "project_ids": [tagProject, tagProject]],
            ["_id": "tag-b", "name": "Course", "color": "hsl(210, 70%, 45%)", "project_ids": [tagProject]],
        ])
        let tags = try OverleafWebClient.parseTags(tagFixture)
        rejects("malformed optional tags fail as a unit") {
            _ = try OverleafWebClient.parseTags(Data(#"[{"_id":"broken","name":"Ignore"}]"#.utf8))
        }
        try check(tags[tagProject]?.count == 2, "tag membership is deduplicated")
        try check(
            tags[tagProject]?.map(\.name) == ["Course", "Research"], "tag names are sorted without changing membership")
        try check(tags[tagProject]?.last?.color == "#e88a33", "tag source colour retained for display adaptation")
    }
}
