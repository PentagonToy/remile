import SwiftUI

@MainActor final class NetworkAccessState: ObservableObject {
    static let shared = NetworkAccessState()
    @Published private(set) var offline = NetworkAccess.offline
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: NetworkAccessGate.changed, object: NetworkAccess.gate, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offline = NetworkAccess.offline }
        }
    }
    func setOffline(_ value: Bool) { NetworkAccess.gate.setOffline(value); offline = value }
}
struct OfflineModeControl: View {
    @ObservedObject private var network = NetworkAccessState.shared
    var body: some View {
        Toggle(isOn: Binding(get: { network.offline }, set: network.setOffline)) { Label("Work offline", systemImage: "airplane") }
            .remileHelp("Pause ChatGPT, Overleaf sync, search boosting, update checks, reference lookups and package lookups. Local documents and standard search remain available.")
    }
}
struct NetworkAccessScope: ViewModifier {
    @ObservedObject private var network = NetworkAccessState.shared
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if network.offline && ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .handled }
            return .systemAction
        })
    }
}
struct OfflineModeButton: View {
    @ObservedObject private var network = NetworkAccessState.shared
    var body: some View {
        Button { network.setOffline(!network.offline) } label: { Image(systemName: "airplane") }
            .font(.system(size: 15, weight: .regular)).frame(width: 32, height: 32).buttonStyle(.plain)
            .foregroundStyle(network.offline ? RemileStyle.accent : RemileStyle.ink.opacity(0.65))
            .accessibilityLabel(network.offline ? "Turn off offline mode" : "Work offline")
            .remileHelp(network.offline ? "Offline mode · click to restore online services" : "Pause all online services in remile.")
    }
}
