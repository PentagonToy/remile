import Foundation
var checks = 0
func verify(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
verify(RemileVersion("0.10.0")! > RemileVersion("0.9.9")!, "Versions compare numerically")
verify(RemileVersion("v0.1.0")!.description == "0.1.0", "Release tags accept v prefix")
for value in ["0.1", "0.1.0-beta", "0.-1.0", "01.0.0", "0.1.0.0", "999999999999999999999.0.0"] { verify(RemileVersion(value) == nil, "Invalid versions rejected") }
func record(_ version: String, draft: Bool = false, prerelease: Bool = false, architecture: String = "arm64", address: String? = nil) -> [String: Any] {
    ["tag_name": "v" + version, "draft": draft, "prerelease": prerelease, "assets": [["name": "remile-\(version)-\(architecture).dmg", "state": "uploaded", "browser_download_url": address ?? "https://github.com/PentagonToy/remile/releases/download/v\(version)/remile-\(version)-\(architecture).dmg"]]]
}
let current = RemileVersion("0.1.0")!
let data = try JSONSerialization.data(withJSONObject: [record("0.1.0"), record("0.2.0"), record("0.10.0"), record("1.0.0", draft: true), record("2.0.0", prerelease: true), record("3.0.0", address: "https://example.invalid/app.dmg"), record("4.0.0", architecture: "x86_64")])
let release = try RemileRelease.newest(data, after: current, architecture: "arm64")
verify(release?.version == RemileVersion("0.10.0"), "Latest compatible stable first-party asset wins")
verify(release?.download.host == "github.com", "Download stays on GitHub")
let unsuitable = try JSONSerialization.data(withJSONObject: [record("0.1.0"), record("0.9.0", draft: true), record("0.8.0", address: "https://example.invalid/app.dmg")])
verify(try! RemileRelease.newest(unsuitable, after: current, architecture: "arm64") == nil, "No offer for current, draft or untrusted assets")
print("\(checks) release checks passed")
