import AppKit
@_cdecl("__isPlatformVersionAtLeast")
public func remoteImageHostVersion(_ a:Int32,_ b:Int32,_ c:Int32)->Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion:Int(a),minorVersion:Int(b),patchVersion:Int(c))) ? 1 : 0 }
final class FakeImageTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var bytes = Data(), response: URLResponse?, error: Error?, finished = false, calls = 0
    init(_ url:URL) { request=URLRequest(url:url) }
    func didReceive(_ response: URLResponse) { self.response=response; calls += 1 }
    func didReceive(_ data: Data) { bytes.append(data); calls += 1 }
    func didFinish() { finished=true; calls += 1 }
    func didFailWithError(_ error: Error) { self.error=error; calls += 1 }
}
let testApp=NSApplication.shared
let port=CommandLine.arguments[1]
var checks=0
func verify(_ condition: @autoclosure ()->Bool,_ message:String) { precondition(condition(),message);checks += 1 }
Task { @MainActor in
 let suite="remile.remote-image-check."+UUID().uuidString
 let defaults=UserDefaults(suiteName:suite)!
 defer { defaults.removePersistentDomain(forName:suite) }
 let gate=NetworkAccessGate(defaults:defaults),handler=MarkdownRemoteImages(gate:gate)
 let view=WKWebView()
 func remote(_ path:String)->URL { URL(string:"http://127.0.0.1:"+port+path)! }
 @MainActor func begin(_ path:String)->FakeImageTask {
  let task=FakeImageTask(MarkdownRemoteImages.sourceURL(for:remote(path))!);handler.webView(view,start:task);return task
 }
 func wait(_ tasks:[FakeImageTask]) async {
  for _ in 0..<600 { if tasks.allSatisfy({$0.finished || $0.error != nil}) { return };try? await Task.sleep(for:.milliseconds(10)) }
  preconditionFailure("Image task timed out")
 }
 func stats()->[String:Any] {
  // Statistics are local synthetic-server data only.
  let bytes=try! Data(contentsOf:remote("/stats"));return try! JSONSerialization.jsonObject(with:bytes) as! [String:Any]
 }
 func count(_ path:String)->Int { (stats()["counts"] as! [String:Int])[path,default:0] }
 verify(MarkdownRemoteImages.sourceURL(for:URL(string:"file:///tmp/image.png")!) == nil,"Reject file URL through remote path")
 verify(MarkdownRemoteImages.sourceURL(for:URL(string:"https://user:pass@example.invalid/a.png")!) == nil,"Reject credential-bearing remote URL")
 let encoded=MarkdownRemoteImages.sourceURL(for:URL(string:"https://example.invalid/a.png?x=1&y=two%20words#part")!)!
 verify(URLComponents(url:encoded,resolvingAgainstBaseURL:false)!.queryItems!.first!.value=="https://example.invalid/a.png?x=1&y=two%20words#part","URL encoding retains query and fragment")
 let first=begin("/image");await wait([first]);verify(first.finished && first.bytes.count>0 && first.response?.mimeType=="image/png","Valid image delivered")
 let cached=begin("/image");await wait([cached]);verify(cached.finished && count("/image")==1,"Identical image uses memory cache")
 let a=begin("/slow-shared"),b=begin("/slow-shared");await wait([a,b]);verify(a.finished && b.finished && count("/slow-shared")==1,"Duplicate live image requests coalesce")
 let bad=begin("/html");await wait([bad]);verify(bad.error != nil && bad.bytes.isEmpty,"Reject non-image response")
 let badAgain=begin("/html");await wait([badAgain]);verify(badAgain.error != nil && count("/html")==1,"Failure cache prevents repeated requests")
 handler.clearFailures();let retried=begin("/html");await wait([retried]);verify(count("/html")==2,"Explicit retry clears only failures")
 let large=begin("/header-large");await wait([large]);verify(large.error != nil && large.bytes.isEmpty,"Reject advertised large image")
 let streamed=begin("/stream-large");await wait([streamed]);verify(streamed.error != nil && streamed.bytes.isEmpty,"Enforce actual byte limit without Content-Length")
 let svg=begin("/svg");await wait([svg]);verify(svg.finished && String(data:svg.bytes,encoding:.utf8)?.contains("<svg")==true,"Passive remote SVG uses shared sanitiser")
 let activeSVG=begin("/svg-active");await wait([activeSVG]);verify(activeSVG.error != nil && activeSVG.bytes.isEmpty,"Active SVG rejected before WebKit delivery")
 let stopped=begin("/slow-stopped");handler.webView(view,stop:stopped);try? await Task.sleep(for:.milliseconds(450));verify(stopped.calls==0,"No callbacks after WebKit stop")
 let online=begin("/hold");gate.setOffline(true);await wait([online]);verify(online.error != nil && online.bytes.isEmpty,"Offline gate cancels active image")
 let offline=begin("/offline-never");await wait([offline]);verify(offline.error != nil && count("/offline-never")==0,"Offline request never reaches transport")
 gate.setOffline(false);handler.clearCache()
 for _ in 0..<250 { if (stats()["active"] as! Int)==0 { break };try? await Task.sleep(for:.milliseconds(10)) }
 let many=(0..<7).map{begin("/slow-limit?i=\($0)")};await wait(many)
 verify(many.allSatisfy(\.finished),"Queued requests all complete")
 let maxActive=stats()["maximum"] as! Int
 verify(maxActive<=3,"At most three downloads run concurrently")
 let refreshed=begin("/image");await wait([refreshed]);verify(count("/image")==2,"Clear releases positive cache")
 let cancelled=(0..<5).map{begin("/slow-cancel?i=\($0)")};handler.cancelAll();await wait(cancelled);verify(cancelled.allSatisfy{$0.error != nil},"cancelAll finishes active and queued requests")
 print("\(checks) remote image checks passed; local synthetic HTTP only.")
 exit(0)
}
testApp.run()
