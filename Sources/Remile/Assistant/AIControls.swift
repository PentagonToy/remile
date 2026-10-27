import SwiftUI

struct GPTMark: View {
    @Environment(\.colorScheme) private var scheme
    private static let source: NSImage = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Brand/chatgpt.svg"), root.appendingPathComponent("others/symbols/providers/chatgpt.svg")]
        return urls.compactMap { $0 }.compactMap { NSImage(contentsOf: $0) }.first ?? NSImage()
    }()
    private static func coloured(_ colour: NSColor) -> NSImage {
        // Native menu labels ignore the SwiftUI tint of this SVG. Preserve the rendered colour.
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            source.draw(in: rect); colour.setFill(); rect.fill(using: .sourceIn); return true
        }
        image.isTemplate = false; return image
    }
    private static let light = coloured(RemileStyle.gold)
    private static let dark = coloured(RemileStyle.amber)
    var body: some View {
        Image(nsImage: scheme == .dark ? Self.dark : Self.light).renderingMode(.original).resizable().scaledToFit().frame(width: 17, height: 17)
            .accessibilityLabel("ChatGPT")
    }
}
struct AIProviderButton: View {
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @ObservedObject private var network = NetworkAccessState.shared
    @AppStorage(AIConfiguration.fallbackPreference) private var fallback = true
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var connection = ChatGPTConnection.shared
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var settings = false }
    var body: some View {
        Menu {
            option("Apple Intelligence", value: "Apple Intelligence")
            option("ChatGPT", value: "ChatGPT")
            option("Manual · AI off", value: "Off")
            if provider == "ChatGPT", let reason = usage.reason { Divider(); Text(reason); if fallback && AppleIntelligence.status().ready { Text("Using Apple Intelligence on this Mac") } }
            if usage.reconnecting { Button("Try ChatGPT again") { usage.retryConnection() } }
            Divider()
            Button("AI settings…") { state.settings = true }
        } label: { AIProviderSymbol().frame(width: RemileControl.toolHit, height: RemileControl.toolHit) }
            .menuStyle(.borderlessButton).tint(RemileStyle.ink).menuIndicator(.hidden).buttonStyle(.plain).frame(width: 32, height: 32, alignment: .center)
            .remileHelp(hint).accessibilityLabel("AI provider").accessibilityValue(provider == "ChatGPT" && fallback && AppleIntelligence.status().ready && usage.reason != nil ? (usage.needsConnection ? "ChatGPT · connection needed" : "Apple Intelligence · automatic fallback") : provider == "Off" ? "Manual · AI off" : provider)
            .sheet(isPresented: $state.settings) { ChatGPTSettings() }
    }
    private func option(_ title: String, value: String) -> some View {
        Toggle(title, isOn: Binding(get: { provider == value }, set: { if $0 { provider = value } })).disabled(value == "Apple Intelligence" && !AppleIntelligence.status().ready)
    }
    private var hint: String {
        if provider == "ChatGPT", (!fallback || !AppleIntelligence.status().ready), let reason = usage.reason { return "ChatGPT · " + reason + (fallback ? ". Apple Intelligence is unavailable on this Mac." : ". Automatic fallback is off.") }
        if provider == "ChatGPT", usage.needsConnection { return "ChatGPT · " + (usage.reason ?? "Connect in AI settings") + ". The dot means the connection needs attention. Using this Mac until ready." }
        if provider == "ChatGPT", let reason = usage.reason { return "Apple Intelligence · " + reason + ". The dot means automatic fallback. ChatGPT returns when available. Click to choose AI." }
        if provider == "ChatGPT" { return "ChatGPT · click to choose AI. " + RemileHints.chatGPTPlan }
        return provider == "Off" ? "Manual · AI is off. Click to choose AI." : "Apple Intelligence · runs on this Mac. Click to choose AI."
    }
}
struct AIProviderSymbol: View {
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @ObservedObject private var network = NetworkAccessState.shared
    @AppStorage(AIConfiguration.fallbackPreference) private var fallback = true
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var connection = ChatGPTConnection.shared
    var body: some View {
        Group {
            if provider == "ChatGPT" && (!fallback || !AppleIntelligence.status().ready || usage.showsGPTMark) { GPTMark() }
            else { SymbolIcon(systemName: provider == "Off" ? "pencil.tip" : "apple.intelligence") }
        }.frame(width: 22, height: 22, alignment: .center).foregroundStyle(RemileStyle.accent)
            .overlay(alignment: .topTrailing) { if provider == "ChatGPT" && usage.reason != nil { Circle().fill(RemileStyle.warning).frame(width: 5, height: 5).overlay(Circle().stroke(RemileStyle.background, lineWidth: 1)).offset(x: 3, y: -2).accessibilityHidden(true) } }
            .opacity(provider == "Off" ? 0.7 : 1)
    }
}
extension AssistantEngine {
    static var selected: Self {
        switch UserDefaults.standard.string(forKey: "assistant.provider") ?? "Apple Intelligence" {
        case "ChatGPT": return .chatGPT
        case "Off": return Self(status: { (false, "AI off") }, respond: { _, _, _ in throw ChatGPTIdentity.Failure("AI off") })
        default: return .onDevice
        }
    }
}

/// Visually groups provider and explicit AI actions throughout the app.
struct AIToolGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { HStack(spacing: RemileControl.spacing) { content() }.buttonStyle(RemileToolStyle()).accessibilityElement(children: .contain) }
}
struct AISettingsRow: View {
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var presented = false }
    var body: some View {
        Button { state.presented = true } label: { HStack { AIProviderSymbol().frame(width: 24, height: 24); Text("AI & writing suggestions"); Spacer(); SymbolIcon(systemName: "chevron.right") }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle()) }.buttonStyle(.plain).remileHelp("Choose AI, writing suggestions and usage limits").sheet(isPresented: $state.presented) { ChatGPTSettings() }
    }
}
