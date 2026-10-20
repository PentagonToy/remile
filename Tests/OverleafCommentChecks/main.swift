import Foundation
let project = OverleafConnection(id: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Example", account: "Personal", branch: "master")
let data = Data(#"{"thread1":{"resolved":true,"resolved_at":"2026-10-20T09:00:00Z","messages":[{"id":"m1","content":"A note with <html> and [links](https://example.com)","timestamp":"2026-10-20T08:00:00Z","user":{"name":"Alex","email":"private@example.com"},"user_id":"user1"},{"id":"m2","content":"A reply","timestamp":"2026-10-20T08:30:00Z","user_id":"user2"}]}}"#.utf8)
let archive = try OverleafThreadArchive.parse(data, project: project)
precondition(archive.threads.count == 1 && archive.threads[0].messages.count == 2)
precondition(archive.threads[0].resolved && archive.threads[0].resolvedAt == "2026-10-20T09:00:00Z")
precondition(archive.threads[0].messages[0].author == "Alex")
let json = try archive.data(json: true), markdown = String(decoding: try archive.data(json: false), as: UTF8.self)
precondition(!String(decoding: json, as: UTF8.self).contains("private@example.com"))
precondition(markdown.contains("Reply") && markdown.contains("&lt;html&gt;") && markdown.contains("\\[links\\]"))
let decoded = try JSONDecoder().decode(OverleafThreadArchive.self, from: json)
precondition(decoded.threads[0].messages[1].id == "m2")
let empty = try OverleafThreadArchive.parse(Data("{}".utf8), project: project)
precondition(empty.threads.isEmpty)
var rejected = false
do { _ = try OverleafThreadArchive.parse(Data(#"{"thread1":{"messages":[{"content":"missing identity"}]}}"#.utf8), project: project) } catch { rejected = true }
precondition(rejected)
print("Passed Overleaf comments: threads/replies/IDs, resolved state/time, Markdown/JSON, email exclusion, literal content, empty response and malformed-message rejection")
