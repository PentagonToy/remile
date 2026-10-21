import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var count = 0
func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
let id = "6ad72e207e5cd74f01fe6b18"
check(OverleafConnection.projectID("https://www.overleaf.com/project/" + id) == id, "project link")
check(OverleafConnection.projectID("https://git@git.overleaf.com/" + id) == id, "official Git URL")
for url in ["http://www.overleaf.com/project/" + id, "https://overleaf.com.evil/project/" + id, "https://www.overleaf.com/project/" + id + "?token=x", "https://password:secret@www.overleaf.com/project/" + id] { check(OverleafConnection.projectID(url) == nil, "reject unsafe URL") }
let serverScript = root.appendingPathComponent("server.py"), portFile = root.appendingPathComponent("port")
try #"""
import http.server,sys,os,subprocess,urllib.parse,json,pathlib
class Git(http.server.BaseHTTPRequestHandler):
 def serve(self):
  parts=urllib.parse.urlsplit(self.path)
  env=os.environ.copy()
  env.update(GIT_PROJECT_ROOT=os.getcwd(),GIT_HTTP_EXPORT_ALL='1',PATH_INFO=urllib.parse.unquote(parts.path),QUERY_STRING=parts.query,REQUEST_METHOD=self.command,CONTENT_TYPE=self.headers.get('Content-Type',''),CONTENT_LENGTH=self.headers.get('Content-Length','0'),REMOTE_USER='fixture')
  data=self.rfile.read(int(env['CONTENT_LENGTH']))
  r=subprocess.run(['/usr/bin/git','http-backend'],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
  if parts.path.endswith('/git-receive-pack') and pathlib.Path('race-edit.json').exists():
   edit=json.loads(pathlib.Path('race-edit.json').read_text()); pathlib.Path(edit['path']).write_text(edit['source']); pathlib.Path('race-edit.json').unlink()
  head,body=r.stdout.split(b'\r\n\r\n',1)
  headers=[line.decode().split(':',1) for line in head.split(b'\r\n')]
  status=next((int(v.strip().split()[0]) for k,v in headers if k.lower()=='status'),200)
  self.send_response(status)
  for k,v in headers:
   if k.lower()!='status': self.send_header(k,v.strip())
  self.end_headers(); self.wfile.write(body)
 do_GET=serve
 do_POST=serve
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Git)
open(sys.argv[1],'w').write(str(s.server_port))
s.serve_forever()
"""#.write(to: serverScript, atomically: true, encoding: .utf8)
let server = Process(); server.executableURL = URL(fileURLWithPath: CommandLine.arguments[2]); server.arguments = [serverScript.path, portFile.path]; server.currentDirectoryURL = root; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
try server.run(); defer { server.terminate(); server.waitUntilExit() }
for _ in 0..<100 { if FileManager.default.fileExists(atPath: portFile.path) { break }; Thread.sleep(forTimeInterval: 0.02) }
let port = try String(contentsOf: portFile, encoding: .utf8)
func git(_ args: [String], at path: URL) throws -> OverleafGit.Result { try OverleafGit.run(args, at: path) }
let seed = root.appendingPathComponent("seed"), remote = root.appendingPathComponent("remote.git"), cache = root.appendingPathComponent("cache")
_ = try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
_ = try git(["config", "http.receivepack", "true"], at: remote)
_ = try git(["init", "--initial-branch=main", seed.path], at: root)
try "Title\nBase\nEnd\n".write(to: seed.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
try "Base reference\n".write(to: seed.appendingPathComponent("reference.tex"), atomically: true, encoding: .utf8)
_ = try git(["add", "-A"], at: seed); _ = try git(["commit", "-m", "Base"], at: seed)
_ = try git(["-c", "protocol.file.allow=always", "push", remote.path, "main"], at: seed); _ = try git(["update-server-info"], at: remote)
_ = try git(["-c", "protocol.file.allow=always", "clone", remote.path, cache.path], at: root)
_ = try git(["remote", "set-url", "origin", "http://127.0.0.1:" + port + "/remote.git"], at: cache)
let transport = "http://127.0.0.1:" + port + "/remote.git"
let project = OverleafConnection(id: UUID(), projectID: id, name: "Synthetic", account: "Test", branch: "main")
func publishFixture(_ message: String) throws {
    _ = try git(["add", "-A"], at: seed); _ = try git(["commit", "-m", message], at: seed)
    _ = try git(["-c", "protocol.file.allow=always", "push", remote.path, "main"], at: seed); _ = try git(["update-server-info"], at: remote)
}
try "Local title\nBase\nEnd\n".write(to: cache.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
try "Remote reference\n".write(to: seed.appendingPathComponent("reference.tex"), atomically: true, encoding: .utf8)
try publishFixture("Remote edit")
let reviews = root.appendingPathComponent("reviews")
let first = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try "Synthetic local-only setting\n".write(to: cache.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
check(try OverleafGit.run(["ls-files", "--others", "--exclude-standard"], at: cache).text.contains(".env") == false, "private local settings stay out of publication")
check(first.changes.count == 2 && !first.changes.contains(where: \.conflict), "nonoverlapping changes merge")
check(try String(contentsOf: cache.appendingPathComponent("reference.tex"), encoding: .utf8) == "Base reference\n", "review never mutates active files")
try OverleafGit.finish(first, choices: [:], publish: false)
check(try String(contentsOf: cache.appendingPathComponent("reference.tex"), encoding: .utf8) == "Remote reference\n", "apply remote change")
check(try String(contentsOf: cache.appendingPathComponent("main.tex"), encoding: .utf8).hasPrefix("Local title"), "preserve local edit")
try "Remote title\nBase\nEnd\n".write(to: seed.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8); try publishFixture("Concurrent title")
let second = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
check(second.changes.contains(where: \.conflict), "overlapping edits require a choice")
var refused = false
do { try OverleafGit.finish(second, choices: [:], publish: false) } catch { refused = true }
check(refused, "unresolved conflicts cannot apply")
try OverleafGit.finish(second, choices: ["main.tex": true], publish: false)
check(try String(contentsOf: cache.appendingPathComponent("main.tex"), encoding: .utf8).hasPrefix("Local title"), "explicit local conflict choice")
let third = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try "New local edit\n".write(to: cache.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
refused = false
do { try OverleafGit.finish(third, choices: [:], publish: false) } catch { refused = true }
check(refused, "source changed after review is refused")
print("Passed \(count) Overleaf URL, merge, conflict, isolation and stale-buffer checks; synthetic local HTTP remote only")

let fourth = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try "Another collaborator\n".write(to: seed.appendingPathComponent("reference.tex"), atomically: true, encoding: .utf8)
try publishFixture("Remote advanced during review")
refused = false
do { try OverleafGit.finish(fourth, choices: [:], publish: false) } catch { refused = true }
check(refused, "remote changed after review is refused")
print("Passed remote-head handshake recheck")

let fifth = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try OverleafGit.finish(fifth, choices: ["main.tex": true], publish: true)
let accepted = try git(["rev-parse", "main"], at: remote).text
check(try git(["rev-parse", "HEAD"], at: cache).text == accepted, "reviewed publish is an ordinary fast-forward push")
let matched = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
check(matched.changes.isEmpty, "matched projects need no change review or duplicate revision")
print("Passed reviewed publish and matched-head checks against synthetic smart HTTP Git")

check(try !OverleafAutoPublisher.needsCheck(project, root: cache, transport: transport), "idle polling skips snapshot work")
try "Automatic title\nBase\nEnd\n".write(to: cache.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
check(try OverleafAutoPublisher.needsCheck(project, root: cache, transport: transport), "local writing triggers snapshot")
let automatic = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
check(try OverleafAutoPublisher.isLocalOnly(automatic), "unchanged remote permits automatic publish")
try OverleafAutoPublisher.publish(automatic)
check(try git(["rev-parse", "HEAD"], at: cache).text == git(["rev-parse", "main"], at: remote).text, "automatic base advances to remote")
check(try String(contentsOf: cache.appendingPathComponent("main.tex"), encoding: .utf8) == "Automatic title\nBase\nEnd\n", "automatic publish preserves working file")
let stale = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try "Still typing\nBase\nEnd\n".write(to: cache.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
refused = false
do { try OverleafAutoPublisher.publish(stale) } catch { refused = true }
check(refused, "automatic publish rejects changed local snapshot")
// Simulate an external edit racing a completed upload: a mixed base advance never replaces that file.
let continued = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
try JSONSerialization.data(withJSONObject: ["path": cache.appendingPathComponent("main.tex").path, "source": "Typing during upload\nBase\nEnd\n"]).write(to: root.appendingPathComponent("race-edit.json"))
try OverleafAutoPublisher.publish(continued)
check(try String(contentsOf: cache.appendingPathComponent("main.tex"), encoding: .utf8) == "Typing during upload\nBase\nEnd\n", "edits during upload remain on disk")
check(try !git(["status", "--porcelain"], at: cache).data.isEmpty, "edits during upload remain pending")
_ = try git(["-c", "protocol.file.allow=always", "fetch", remote.path, "main"], at: seed)
_ = try git(["reset", "--hard", "FETCH_HEAD"], at: seed)
try "New remote reference\n".write(to: seed.appendingPathComponent("reference.tex"), atomically: true, encoding: .utf8)
try publishFixture("External edit")
try "More local writing\nBase\nEnd\n".write(to: cache.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
let remoteChanged = try OverleafGit.prepare(project, root: cache, reviewRoot: reviews, transport: transport)
check(try !OverleafAutoPublisher.isLocalOnly(remoteChanged), "remote edits require manual review even without conflicts")
refused = false
do { try OverleafAutoPublisher.publish(remoteChanged) } catch { refused = true }
check(refused, "automatic publish cannot accept remote edits")
print("Passed local-only automatic publishing, stale snapshot refusal and remote review boundary")
