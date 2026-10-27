import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

struct ControlSpecimen: View {
    var compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("A little room to think.").font(RemileType.windowTitle)
            HStack(spacing: 8) {
                Text("Markdown").font(RemileType.heading)
                Button {} label: { Image(systemName: "list.bullet.indent") }.accessibilityLabel("Document outline")
                Spacer()
                if compact {
                    Menu("Read") { Button("Edit") {}; Button("Split") {} }.menuStyle(.borderlessButton)
                } else {
                    RemileSegmentedControl(title: "Document mode", selection: .constant("Read"), options: ["Read", "Edit", "Split"], label: { $0 }).frame(width: 210)
                }
                Button {} label: { Image(systemName: "text.bubble") }.accessibilityLabel("Ask")
                Button {} label: { Image(systemName: "books.vertical") }.accessibilityLabel("Reference library")
                Menu { Button("PDF…") {} } label: { DocumentActionIcon(action: .export).frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(RemileStyle.ink).accessibilityLabel("Export")
            }.buttonStyle(RemileToolStyle()).padding(12).background(RemileStyle.editorBar)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Search", systemImage: "magnifyingglass").labelStyle(RemileNavigationLabelStyle())
                    Label("Reference", systemImage: "books.vertical").labelStyle(RemileNavigationLabelStyle())
                    Label("Settings", systemImage: "gearshape").labelStyle(RemileNavigationLabelStyle())
                }.frame(width: 140, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reference").font(RemileType.section)
                    Text("Records and attached PDFs stay together.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    HStack {
                        Button("Add PDF…") {}.buttonStyle(RemileActionStyle(emphasis: .primary))
                        Button("Cancel") {}.buttonStyle(RemileActionStyle())
                        Button("Unavailable") {}.buttonStyle(RemileActionStyle()).disabled(true)
                    }
                }
            }
        }.padding(24).font(RemileType.control).tint(RemileStyle.accent).foregroundStyle(RemileStyle.ink).background(RemileStyle.background)
    }
}

func luminance(_ colour: NSColor) -> Double {
    let colour = colour.usingColorSpace(.sRGB)!
    let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var ratios: [String: Double] = [:]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            application.appearance = appearance
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor(RemileStyle.background)
                for (name, colour) in [("ink", RemileStyle.ink), ("secondary", RemileStyle.secondaryInk), ("accent", RemileStyle.accent)] {
                    let value = contrast(NSColor(colour), background)
                    ratios[(dark ? "dark-" : "light-") + name] = value
                    precondition(value >= 4.5, name + " needs readable small-text contrast")
                }
            }
            for compact in [false, true] {
                let width = compact ? 560.0 : 760.0
                let host = NSHostingView(rootView: ControlSpecimen(compact: compact).environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: 340))
                host.appearance = appearance; host.frame = NSRect(x: 0, y: 0, width: width, height: 340)
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = (dark ? "dark" : "light") + (compact ? "-compact.png" : "-regular.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
        try JSONSerialization.data(withJSONObject: ratios, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("contrast.json"))
        print("6 contrast checks and 4 component captures passed")
        exit(0)
    } catch { print(error); exit(1) }
}
application.run()
