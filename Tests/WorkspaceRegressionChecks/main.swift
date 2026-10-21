import AppKit
import SwiftUI
import PDFKit
import CoreText
@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
 ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
@MainActor func settle(_ condition: () -> Bool) async -> Bool {
 for _ in 0..<150 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
 return false
}
func fixture() -> Data {
 let data = NSMutableData(); var box = CGRect(x: 0,y: 0,width: 612,height: 792)
 let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box,nil)!
 for i in 1...8 { context.beginPDFPage(nil); context.textPosition = CGPoint(x: 50,y: 600); CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:"Page \(i)",attributes:[.font:NSFont.systemFont(ofSize:20)])),context); context.endPDFPage() }
 context.closePDF(); return data as Data
}
@MainActor func pdf(in view: NSView) -> PDFView? {
 if let pdf = view as? PDFView { return pdf }
 for child in view.subviews { if let found = pdf(in:child) { return found } }
 return nil
}
Task { @MainActor in
 var policyChecks = 0
 func policy(_ value: Bool) { precondition(value); policyChecks += 1 }
 policy(OverleafSignInSession.isProjectPage(URL(string:"https://www.overleaf.com/project/abc")!))
 policy(!OverleafSignInSession.isProjectPage(URL(string:"https://example.com/project/abc")!))
 for (status, mime, expected) in [(200,"application/json; charset=utf-8",true),(401,"application/json",false),(200,"text/html",false)] {
     let response = HTTPURLResponse(url:URL(string:"https://www.overleaf.com/user/projects")!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":mime])!
     policy(OverleafSignInSession.isAuthenticatedProjectList(response) == expected)
 }
 let unrelated = HTTPURLResponse(url:URL(string:"https://example.com/user/projects")!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
 policy(!OverleafSignInSession.isAuthenticatedProjectList(unrelated))
 print("Passed",policyChecks,"Overleaf sign-in navigation policies")
 let session = PDFSession(); session.showsSidebar = true; let bytes = fixture()
 let host = NSHostingView(rootView: PDFWorkspace(data:bytes,session:session,showAsk:true,updateDocument:{_ in}))
 let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:850),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
 guard await settle({pdf(in:host)?.bounds.width ?? 0 > 100}), let view = pdf(in:host) else { print("FAILED initial view"); exit(1) }
 view.layoutDocumentView(); session.goToPage(5)
 _ = await settle({view.currentPage === session.document?.page(at:4)})
 let identity = ObjectIdentifier(view), width = view.bounds.width
 session.showsSidebar = false; host.layoutSubtreeIfNeeded()
 _ = await settle({pdf(in:host)?.bounds.width != width})
 let same = pdf(in:host).map { ObjectIdentifier($0) == identity } ?? false
 let actual = pdf(in:host)?.currentPage.map {session.document!.index(for:$0)+1} ?? 0
 print("PDF identity retained:",same,"actual page:",actual,"reported:",session.currentPage)
 guard same && actual == 5 && session.currentPage == 5 else { exit(1) }
 session.showsSidebar = true; host.layoutSubtreeIfNeeded()
 _ = await settle({pdf(in:host)?.bounds.width == width})
 guard pdf(in:host) === view && view.currentPage === session.document?.page(at:4) else { print("FAILED sidebar restored");exit(1) }
 print("Passed PDF workspace sidebar identity and page retention")
 window.orderOut(nil)
 @MainActor func render<V: View>(_ root: V, name: String, size: NSSize, dark: Bool) async {
     let view = NSHostingView(rootView: root.environment(\.colorScheme,dark ? .dark : .light))
     let shell = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
     shell.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
     shell.contentView=view; shell.orderFront(nil); view.layoutSubtreeIfNeeded()
     await Task.yield(); view.layoutSubtreeIfNeeded()
     if let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
         view.cacheDisplay(in:view.bounds,to:rep)
         if let bytes=rep.representation(using:.png,properties:[:]) { try! bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".png")) }
     }
     shell.orderOut(nil)
 }
 let badRoot = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("failure-fixture")
 try! FileManager.default.createDirectory(at:badRoot,withIntermediateDirectories:true)
 try! "\\documentclass{article}\n\\begin{document}Test\\end{document}".write(to:badRoot.appendingPathComponent("main.tex"),atomically:true,encoding:.utf8)
 try! "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 20 20\nnot-a-postscript-command".write(to:badRoot.appendingPathComponent("broken.eps"),atomically:true,encoding:.utf8)
 let badProject = try! TeXProject(badRoot,historyEnabled:false)
 badProject.compile(output:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("failure-build"))
 guard await settle({!badProject.compiling}), badProject.showsLog, badProject.log.contains("EPS"), badProject.log.contains("Ghostscript") || badProject.log.contains("Error") else { print("FAILED compile errors preserve diagnostics",badProject.log);exit(1) }
 print("Passed EPS failure retains diagnostics and opens build log")
 let dependencyRoot = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("missing-package-fixture")
 try! FileManager.default.createDirectory(at:dependencyRoot,withIntermediateDirectories:true)
 try! "\\documentclass{article}\n\\usepackage{remile-absent-spec}\n\\begin{document}Test\\end{document}".write(to:dependencyRoot.appendingPathComponent("main.tex"),atomically:true,encoding:.utf8)
 let dependencyProject = try! TeXProject(dependencyRoot,historyEnabled:false)
 dependencyProject.compile(output:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("missing-package-build"))
 guard await settle({!dependencyProject.compiling}), dependencyProject.compileFailed, dependencyProject.setupNeeded, dependencyProject.setupIssue?.files == ["remile-absent-spec.sty"] else { print("FAILED missing package does not open setup guide",dependencyProject.log);exit(1) }
 print("Passed missing package opens contextual setup guide")
 dependencyProject.setupNeeded = false
 guard dependencyProject.compileFailed else { print("FAILED dismissed guidance lost failure state"); exit(1) }
 dependencyProject.buffers["main.tex"] = "\\documentclass{article}\n\\begin{document}\\remileUndefinedCommand\\end{document}"
 dependencyProject.compile(output:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("syntax-error-build"))
 guard await settle({!dependencyProject.compiling}), dependencyProject.compileFailed, dependencyProject.setupNeeded, dependencyProject.setupIssue == nil, TeXDiagnostics.primaryError(dependencyProject.diagnostics)?.message.contains("Undefined control sequence") == true else { print("FAILED source error does not open diagnostic guidance",dependencyProject.log);exit(1) }
 await render(TeXCompileGuidance(project:dependencyProject,showDiagnostics:{}),name:"source-error-guidance",size:NSSize(width:490,height:240),dark:true)
 dependencyProject.buffers["main.tex"] = "\\documentclass{article}\n\\begin{document}Test\\end{document}"
 dependencyProject.compile(output:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("recovery-build"))
 guard await settle({!dependencyProject.compiling}), !dependencyProject.compileFailed, !dependencyProject.setupNeeded, dependencyProject.outputCurrent, dependencyProject.pdf != nil else { print("FAILED successful compile retains error guidance",dependencyProject.log);exit(1) }
 print("Passed source error guidance, dismissal retention and successful compilation recovery")
 dependencyProject.log = "./main.tex:43: Font U/rsfs/m/n/10=rsfs10 at 10pt not loadable: Metric (TFM) file not found."
 dependencyProject.diagnostics = TeXDiagnostics.parse(dependencyProject.log)
 let fontResolution = TeXPackageResolution(owners:["rsfs10.tfm":["rsfs"]])
 await render(TeXCompileGuidance(project:dependencyProject,showDiagnostics:{},resolution:fontResolution),name:"font-error-guidance",size:NSSize(width:490,height:420),dark:true)
 let comparisonLibrary = OverleafLibrary(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("comparison-library"))
 let comparisonConnection = OverleafConnection(id:UUID(),projectID:"000000000000000000000000",name:"Comparison fixture",account:"fixture",branch:"master")
 let comparisonText = (1...60).map { "\\section{Section \($0)}" }.joined(separator:"\n")
 let change = OverleafGit.Change(path:"main.tex",local:comparisonText,remote:comparisonText + "\n% Remote note",result:comparisonText + "\n% Remote note",conflict:false)
 let comparisonReview = OverleafGit.Review(connection:comparisonConnection,root:badRoot,stage:badRoot,fingerprint:"fixture",remoteHead:"fixture",transport:"fixture",changes:[change],localChanges:false)
 let comparisonHost = NSHostingView(rootView:OverleafComparison(library:comparisonLibrary,review:comparisonReview,reload:{_ in}).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
 let comparisonWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:480),styleMask:[.titled],backing:.buffered,defer:false)
 let comparisonParent = NSWindow(contentRect:NSRect(x:0,y:0,width:1600,height:1000),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 comparisonParent.contentView=NSView(); comparisonParent.orderFront(nil)
 comparisonWindow.contentView=comparisonHost; comparisonParent.beginSheet(comparisonWindow, completionHandler:nil)
 guard await settle({comparisonWindow.styleMask.contains(.resizable) && comparisonHost.bounds.width > 760}) else { print("FAILED comparison window is not resizable");exit(1) }
 comparisonWindow.setContentSize(NSSize(width:1280,height:800)); comparisonHost.layoutSubtreeIfNeeded()
 guard await settle({comparisonHost.bounds.width == 1280 && comparisonHost.bounds.height == 800}) else { print("FAILED comparison does not expand");exit(1) }
 if let rep=comparisonHost.bitmapImageRepForCachingDisplay(in:comparisonHost.bounds) { comparisonHost.cacheDisplay(in:comparisonHost.bounds,to:rep); try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("comparison-wide.png")) }
 comparisonWindow.setContentSize(NSSize(width:800,height:520)); comparisonHost.layoutSubtreeIfNeeded()
 guard await settle({comparisonHost.bounds.width == 800 && comparisonHost.bounds.height == 520}) else { print("FAILED comparison does not shrink");exit(1) }
 if let rep=comparisonHost.bitmapImageRepForCachingDisplay(in:comparisonHost.bounds) { comparisonHost.cacheDisplay(in:comparisonHost.bounds,to:rep); try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("comparison-small.png")) }
 comparisonParent.endSheet(comparisonWindow); comparisonWindow.orderOut(nil); comparisonParent.orderOut(nil)
 print("Passed comparison attached-sheet native resize from 1280x800 to 800x520")
 let adviceFixture = try! TeXDiagnosticAdvice.parse(#"{"summary":"The compiler could not load a font.","steps":["Install the package identified by TeX Live.","Compile again to check the remaining document."],"commands":["sudo '/Library/TeX/texbin/tlmgr' install courier"]}"#)
 await render(TeXDiagnosticAdviceContent(advice:adviceFixture,model:"Fixture model").padding(20).foregroundStyle(RemileStyle.ink).background(RemileStyle.background),name:"ai-guidance-structure",size:NSSize(width:490,height:280),dark:true)
 let index = LibraryIndex(location:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("empty-library.sqlite"))
 let model = HomeModel(index:index)
 await render(LibraryManager(model:model),name:"library-empty-dark",size:NSSize(width:620,height:420),dark:true)
 await render(ReaderSettings(),name:"settings-dark",size:NSSize(width:720,height:560),dark:true)
 await render(ReaderSettings(),name:"settings-light",size:NSSize(width:720,height:560),dark:false)
 let packageResolution = TeXPackageResolution(owners:["soul.sty":["soul"],"appendix.sty":["appendix"],"framed.sty":["framed"],"newtxmath.sty":["newtx"]])
 await render(TeXSetupGuide(missing:[],issue:TeXSetupIssue(files:["soul.sty","appendix.sty","framed.sty","newtxmath.sty"]),resolution:packageResolution),name:"missing-packages-guide",size:NSSize(width:490,height:300),dark:true)
 await render(TeXSettings().background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent),name:"environment-check-settings",size:NSSize(width:600,height:950),dark:true)
 let environmentReport = TeXEnvironmentReport(projectChecked:true,checkedFiles:35,missingTools:[],missingFiles:["soul.sty","newtxmath.sty"],unverifiedFiles:[],needsGhostscript:false)
 await render(TeXEnvironmentResult(report:environmentReport,directory:"/Library/TeX/texbin",resolution:packageResolution),name:"environment-check-result",size:NSSize(width:530,height:400),dark:true)
 print("Rendered settings check action and actionable environment result")
 let sidebarRoot = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("sidebar-fixture")
 try! FileManager.default.createDirectory(at:sidebarRoot,withIntermediateDirectories:true)
 try! ("\\documentclass{article}\n\\begin{document}\n" + (1...100).map { "\\section{Long project heading \($0) to exercise scrolling and layout}" }.joined(separator:"\n") + "\n\\end{document}").write(to:sidebarRoot.appendingPathComponent("main.tex"),atomically:true,encoding:.utf8)
 let sidebarProject = try! TeXProject(sidebarRoot,historyEnabled:false), sidebarState = TeXSidebarState()
 let sidebarHost = NSHostingView(rootView:TeXProjectSidebar(project:sidebarProject,state:sidebarState).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent))
 let sidebarWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:280,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 sidebarWindow.contentView=sidebarHost;sidebarWindow.orderFront(nil)
 for _ in 0..<3 { for (files,outline) in [(false,true),(true,false),(false,false),(true,true)] {
     sidebarState.files=files;sidebarState.outline=outline
     await Task.yield();sidebarHost.layoutSubtreeIfNeeded()
     guard sidebarHost.fittingSize.height <= 701 && sidebarHost.bounds.height <= 701 && sidebarWindow.contentView!.bounds.height <= 701 else { print("FAILED sidebar disclosure grows window",files,outline,sidebarHost.fittingSize,sidebarHost.bounds,sidebarWindow.frame);exit(1) }
 } }
 sidebarState.files=false;sidebarState.outline=true
 await render(TeXProjectSidebar(project:sidebarProject,state:sidebarState).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent),name:"tex-outline-expanded",size:NSSize(width:280,height:700),dark:true)
 sidebarWindow.orderOut(nil)
 print("Passed 12 bounded LaTeX sidebar disclosure transitions with 100 headings")
 let outlined=PDFDocument(data:bytes)!,outlineRoot=PDFOutline()
 for (index,title) in ["Cover","Half-title","Introduction"].enumerated() { let item=PDFOutline();item.label=title;item.destination=PDFDestination(page:outlined.page(at:index)!,at:.zero);outlineRoot.insertChild(item,at:index) }
 outlined.outlineRoot=outlineRoot
 let outlinedBytes=outlined.dataRepresentation()!
 for tab in [PDFSession.Sidebar.pages,.outline,.comments,.highlights] {
     let panelSession=PDFSession();panelSession.showsSidebar=true;panelSession.sidebar=tab
     await render(PDFWorkspace(data:outlinedBytes,session:panelSession,updateDocument:{_ in}),name:"pdf-sidebar-"+tab.rawValue.lowercased(),size:NSSize(width:1200,height:850),dark:true)
 }
 let saveURL=sidebarRoot.appendingPathComponent("same-file.md"), reader=ReadingSession()
 try! "Original".write(to:saveURL,atomically:true,encoding:.utf8)
 try! reader.open(saveURL,recordRecent:false);reader.document.content = .markdown("Edited")
 try! FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:100)],ofItemAtPath:saveURL.path)
 guard reader.dirty && reader.save() && !reader.dirty && (try! String(contentsOf:saveURL,encoding:.utf8)) == "Edited" else { print("FAILED same-file save");exit(1) }
 let beforeTeX=sidebarProject.buffers["main.tex"]!
 sidebarProject.buffers["main.tex"] = beforeTeX + "\n% Local edit"
 guard sidebarProject.dirty && sidebarProject.save() && !sidebarProject.dirty else { print("FAILED TeX same-file save");exit(1) }
 print("Passed same-path Markdown/LaTeX save, including timestamp-only external change")
 exit(0)
}
app.run()
