import SwiftUI
import AppKit

@MainActor final class RemileUpdates: ObservableObject {
    static let shared = RemileUpdates()
    @Published private(set) var checking = false
    @Published private(set) var release: RemileRelease?
    @Published private(set) var message: String?
    func check() async {
        guard !checking, let current = RemileVersion(RemileRelease.current) else { return }
        checking = true; message = nil; release = nil
        defer { checking = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/PentagonToy/remile/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("remile-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            let lease = try NetworkAccess.gate.watch(session); defer { NetworkAccess.gate.release(lease) }
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 { message = "No public release is available yet."; return }
            guard http.statusCode == 200, response.expectedContentLength <= 524_288 else { throw URLError(.badServerResponse) }
            var bytes = Data()
            for try await byte in stream { guard bytes.count < 524_288 else { throw URLError(.dataLengthExceedsMaximum) }; bytes.append(byte) }
            release = try RemileRelease.newest(bytes, after: current)
            message = release == nil ? "No newer compatible release is available." : nil
        } catch { message = "Couldn’t check for updates. Try again when you’re online." }
    }
}

struct RemileUpdateSettings: View {
    @ObservedObject private var updates = RemileUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("remile. \(RemileRelease.current)").monospacedDigit()
                Spacer()
                Button(updates.checking ? "Checking…" : "Check for updates") { Task { await updates.check() } }.disabled(updates.checking)
            }
            if let release = updates.release {
                HStack { Text("Version \(release.version.description) is available."); Spacer(); Link("Download update…", destination: release.download) }
            }
            if let message = updates.message { Text(message).foregroundStyle(.secondary) }
            Link("Release notes…", destination: RemileRelease.page).buttonStyle(.plain).font(RemileType.small)
        }
    }
}
