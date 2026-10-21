import Foundation

/// Keep the user's provider choice separate from temporary connectivity and availability.
enum AIConfiguration {
    enum Mode: String, CaseIterable { case manual = "Off", device = "Apple Intelligence", gpt = "ChatGPT"
        var label: String { switch self { case .manual: "Manual"; case .device: "Apple Intelligence"; case .gpt: "ChatGPT" } }
    }
    static let fallbackPreference = "assistant.deviceFallback"
    static let writingPreference = "assistant.writingEnabled"
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: "assistant.provider") ?? "") ?? .device }
    static var fallbackEnabled: Bool { UserDefaults.standard.object(forKey: fallbackPreference) as? Bool ?? true }
    static var writingEnabled: Bool { UserDefaults.standard.object(forKey: writingPreference) as? Bool ?? true }
    enum Route: Equatable { case off, device, gpt, unavailable }
    static func route(mode: Mode, gptReady: Bool, deviceReady: Bool, fallback: Bool) -> Route {
        switch mode {
        case .manual: return .off
        case .device: return deviceReady ? .device : .unavailable
        case .gpt: return gptReady ? .gpt : fallback && deviceReady ? .device : .unavailable
        }
    }
}
