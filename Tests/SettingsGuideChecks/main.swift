import AppKit
import SwiftUI
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
 ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
final class AnchorProbe { var frames: [String: CGRect] = [:] }
struct ProbedHome: View {
 let model: HomeModel, progress: WelcomeTourProgress, probe: AnchorProbe
 let defaults: UserDefaults
 var body: some View {
  HomeWorkspace(model:model,loadOnAppear:false,tourProgress:progress).defaultAppStorage(defaults)
   .overlayPreferenceValue(TourTarget.self) { anchors in GeometryReader { geometry in record(anchors, geometry) } }
 }
 func record(_ anchors: [String: Anchor<CGRect>], _ geometry: GeometryProxy) -> Color { probe.frames = anchors.mapValues { geometry[$0] }; return .clear }
}
@MainActor func wait(_ condition: () -> Bool) async -> Bool {
 for _ in 0..<100 { if condition() { return true };try? await Task.sleep(for:.milliseconds(20)) };return false
}
@MainActor func raster(_ view: NSView, _ name: String) {
 view.layoutSubtreeIfNeeded()
 if let image=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:image);try! image.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))}
}
Task { @MainActor in
 try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
 var easing=ScrollEase(position:0,target:0);easing.add(100,lower:0,upper:500)
 let first=easing.advance(seconds:1.0/60);precondition(first>0 && first<100)
 easing.add(100,lower:0,upper:500);precondition(easing.target==200)
 var previous=first
 for _ in 0..<100 {let next=easing.advance(seconds:1.0/60);precondition(next>=previous && next<=200);previous=next}
 precondition(easing.position==200);easing.add(10000,lower:0,upper:500);precondition(easing.target==500)
 print("Passed wheel easing/coalescing/bounds checks")
 let defaults=UserDefaults(suiteName:"remile.guide-tests."+UUID().uuidString)!
 defaults.set(false,forKey:"welcome.tourCompleted.v1")
 let library=OverleafLibrary(directory:output.appendingPathComponent("IsolatedOverleaf"))
 let model=HomeModel(index:LibraryIndex(location:output.appendingPathComponent("library.sqlite")),overleaf:library)
 let progress=WelcomeTourProgress(),probe=AnchorProbe()
 let host=NSHostingView(rootView:ProbedHome(model:model,progress:progress,probe:probe,defaults:defaults).environment(\.colorScheme,.dark))
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.orderFront(nil)
 for size in [NSSize(width:1200,height:800),NSSize(width:720,height:560)] {
  window.setContentSize(size)
  for i in 0..<WelcomeTour.steps.count {
   progress.step=i;host.layoutSubtreeIfNeeded()
   let found = await wait { probe.frames[WelcomeTour.steps[i].target] != nil }
   precondition(found,"Missing actual Home target at step \(i+1)")
   try? await Task.sleep(for:.milliseconds(650))
   precondition(host.bounds.height<=size.height+1,"Tour grew the window")
  }
 }
 raster(host,"home-tour-final")
 precondition(!defaults.bool(forKey:"welcome.tourCompleted.v1"),"Inspecting steps completed tutorial unexpectedly")
 window.orderOut(nil)
 print("Passed all eight actual Home anchors at wide/narrow sizes, including nested editor targets and step 2→3")
 let guideState=UserGuidePresentation()
 let guide=NSHostingView(rootView:UserGuide(presentation:guideState).environment(\.colorScheme,.dark).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
 let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:620),styleMask:[.titled],backing:.buffered,defer:false)
 sheet.appearance=NSAppearance(named:.darkAqua);sheet.contentView=guide;sheet.orderFront(nil);guide.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(200));raster(guide,"guide-collapsed")
 guideState.more=true;try? await Task.sleep(for:.milliseconds(400));guide.layoutSubtreeIfNeeded();raster(guide,"guide-expanded")
 precondition(guide.bounds.size==NSSize(width:700,height:620));sheet.orderOut(nil)
 print("Rendered fixed-width guide cards before/after disclosure and header actions")
 let settings=NSHostingView(rootView:ReaderSettings().environment(\.colorScheme,.dark).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
 let settingsWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:560),styleMask:[.titled],backing:.buffered,defer:false)
 settingsWindow.appearance=NSAppearance(named:.darkAqua);settingsWindow.contentView=settings;settingsWindow.orderFront(nil);settings.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(200));raster(settings,"settings-general")
 settingsWindow.orderOut(nil)
 let ai=NSHostingView(rootView:Form { Section("Connection & usage") { ChatGPTSettings(showsHeading:false) } }.formStyle(.grouped).scrollContentBackground(.hidden).background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent).environment(\.colorScheme,.dark))
 let aiWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:640),styleMask:[.titled],backing:.buffered,defer:false);aiWindow.appearance=NSAppearance(named:.darkAqua);aiWindow.contentView=ai;aiWindow.orderFront(nil);ai.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(200));raster(ai,"settings-ai")
 print("Rendered AI settings without an embedded opaque panel background")
 exit(0)
}
app.run()
