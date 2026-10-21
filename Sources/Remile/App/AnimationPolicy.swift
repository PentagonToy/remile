import AppKit

/// Shared by SwiftUI surfaces and native controls; absent preferences keep motion enabled.
enum AnimationPolicy {
    static let preference = "appearance.animations"
    static func enabled(defaults: UserDefaults = .standard, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Bool {
        (defaults.object(forKey: preference) as? Bool ?? true) && !reduceMotion
    }
}
