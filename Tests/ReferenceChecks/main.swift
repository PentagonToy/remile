import AppKit
import Foundation
import PDFKit
import CoreText

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }; checks += 1
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: " + label) } catch { checks += 1 }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let root = output.appendingPathComponent("library")
let repository = ReferenceRepository(root: root, keyRule: .surnameYearWord)
try check(repository.records().isEmpty, "Empty library")
try check(!FileManager.default.fileExists(atPath: root.path), "Reading does not create a library")
let bib = #"""
% A synthetic bibliography
@string{venue = "Example " # "Journal"}
@article{oldKey,
 title = {A {Nested} Title},
 author = {Kang, Hanseul and Doe, Jane},
 year = 2026,
 journal = venue,
 month = jan,
 doi = {10.0000/example},
 customfield = {Preserve this field}
}
@book(otherKey, title="Second {Example}", author={Jane Doe}, year={2025})
"""#
let parsed = try ReferenceBibTeX.parse(bib)
try check(parsed.count == 2, "Parse multiple entries")
try check(parsed[0].fields["journal"] == "Example Journal", "Expand string concatenation")
try check(parsed[0].fields["month"] == "Jan", "Predefined month")
try check(parsed[0].fields["title"] == "A {Nested} Title", "Preserve inner braces")
let roundTrip = try ReferenceBibTeX.parse(ReferenceBibTeX.export(parsed))
try check(roundTrip.map(\.fields) == parsed.map(\.fields), "Field round trip")
try check(ReferenceKeyRule.surnameYearWord.key(for: parsed[0]) == "Kang_2026_Nested", "Surname/year/first meaningful title word")
try check(ReferenceKeyRule.surnameYearTwoWords.key(for: parsed[0]) == "Kang_2026_Nested_Title", "Surname/year/two meaningful title words")
try check(ReferenceKeyRule.surnameYear.key(for: parsed[1]) == "Doe_2025", "Family name without comma")
var unknown = ReferenceRecord(); unknown.fields["title"] = "Uncertain title"
try check(ReferenceKeyRule.surnameYearWord.key(for: unknown) == "Reference_nd_Uncertain", "Unknown author/year are explicit")
var accents = parsed[0]; accents.fields["author"] = "García, Ana"; accents.fields["title"] = #"{\textit{École}} Study"#
try check(ReferenceKeyRule.surnameYearWord.key(for: accents) == "Garcia_2026_Ecole", "Portable keys remove TeX commands and accents")
for invalid in ["not BibTeX", "@article{x,title={Unclosed}", "@article{x,title=unknown}", "@article{x,title={a},title={b}}", "@article{x,title={a}} @article{x,title={b}}", "@article{x,title=}", "@article{x,title={a} year={2026}}"] {
    rejects("Malformed bibliography") { _ = try ReferenceBibTeX.parse(invalid) }
}
let added = try repository.add(parsed)
try check(added[0].key == "Kang_2026_Nested", "Import uses the fixed preset")
try check(added[0].originalKey == "oldKey", "Original citation key retained as provenance")
try check(added[0].id == parsed[0].id, "Stable record identity")
try check(try ReferenceRepository(root: root).records() == added, "Catalogue survives reload")
var edited = added[0]; edited.fields["title"] = "Renamed paper"; edited.key = "custom-key"
let renamed = try repository.update(edited, expected: edited.revision)
try check(renamed.key == added[0].key, "Editing a title cannot silently regenerate a key")
try check(renamed.revision != edited.revision, "Revision changes on edit")
rejects("Stale revision") { _ = try repository.update(edited, expected: edited.revision) }
try check(try repository.records().first(where: { $0.id == renamed.id })?.title == "Renamed paper", "Stale edit did not overwrite")
let duplicate = try repository.duplicate(added[1].id)
try check(duplicate.id != added[1].id && duplicate.key != added[1].key, "Duplicate has independent identity and key")
try check(duplicate.key.hasSuffix("_2"), "Numbered collision suffix")
try repository.trash(duplicate.id)
try check(try repository.records().first(where: { $0.id == duplicate.id })?.trashed != nil, "Delete is recoverable")
try repository.trash(duplicate.id, restore: true)
try check(try repository.records().first(where: { $0.id == duplicate.id })?.trashed == nil, "Restore from Trash")
let pdf = PDFDocument(); let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox); pdf.insert(page, at: 0)
pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Synthetic PDF", PDFDocumentAttribute.authorAttribute: "Jane Doe"]
let pdfURL = output.appendingPathComponent("fixture.pdf")
guard let pdfBytes = pdf.dataRepresentation() else { fatalError("Fixture generation") }; try pdfBytes.write(to: pdfURL)
let attached = try repository.importFiles([pdfURL], attachingTo: renamed.id, expected: renamed.revision)[0]
try check(attached.id == renamed.id && attached.attachments.count == 1, "Attach PDF to bibliography-only item")
try check(attached.key == renamed.key, "Attaching preserves citation key")
try check(try Data(contentsOf: repository.attachmentURL(attached.attachments[0])) == pdfBytes, "Managed attachment bytes")
try check(try Data(contentsOf: pdfURL) == pdfBytes, "Original PDF remains unchanged")
let attachedCopy = try repository.duplicate(attached.id)
try check(attachedCopy.attachments == attached.attachments, "Duplicate shares immutable attachment revision")
rejects("Attach against stale revision") { _ = try repository.importFiles([pdfURL], attachingTo: attached.id, expected: renamed.revision) }
let newPDF = try repository.importFiles([pdfURL])[0]
try check(newPDF.title == "Synthetic PDF", "Use PDF title metadata")
try check(newPDF.year.isEmpty, "Do not invent publication year from PDF creation date")
let bibURL = output.appendingPathComponent("fixture.bib"); try Data(bib.utf8).write(to: bibURL)
let importedBib = try repository.importFiles([bibURL])
try check(importedBib.count == 2 && importedBib.allSatisfy { $0.attachments.isEmpty }, "Bibliography-only import")
let beforeFailure = try Data(contentsOf: root.appendingPathComponent("library.json"))
let bad = output.appendingPathComponent("bad.txt"); try Data("not a PDF".utf8).write(to: bad)
let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Attachments").path)
rejects("Mixed invalid batch") { _ = try repository.importFiles([pdfURL, bad]) }
try check(try Data(contentsOf: root.appendingPathComponent("library.json")) == beforeFailure, "Failed import is atomic")
try check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Attachments").path).sorted() == filesBefore.sorted(), "Failed import removes only its staged copies")
let symlink = output.appendingPathComponent("linked.pdf"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: pdfURL)
rejects("Symlink import") { _ = try repository.importFiles([symlink]) }
try repository.trash(added[1].id)
let trashBefore = try repository.records().first { $0.id == added[1].id }!
let changed = try repository.regenerate(rule: .surnameYear)
try check(changed > 0, "Whole-library key regeneration")
try check(try repository.records().first { $0.id == added[1].id } == trashBefore, "Whole regeneration leaves Trash unchanged")
let allKeys = try repository.records().map(\.key)
try check(Set(allKeys.map { $0.lowercased() }).count == allKeys.count, "Keys remain unique across active and Trash")
try check(try repository.regenerate(rule: .surnameYear) == 0, "Regeneration is deterministic and idempotent")
let current = try repository.records().first { $0.id == attached.id }!
let countBefore = try repository.records().count
_ = try repository.regenerate(id: current.id, expected: current.revision, rule: .surnameYearTwoWords)
try check(try repository.records().count == countBefore, "Individual regeneration changes no membership")
rejects("Stale individual key request") { _ = try repository.regenerate(id: current.id, expected: current.revision, rule: .surnameYearWord) }
let listing = try ReferenceCLI.response(["list", "--limit", "2", "--offset", "0"], repository: repository)
try check((listing["references"] as? [[String: Any]])?.count == 2, "CLI paginates")
let detail = try ReferenceCLI.response(["show", "--id", attached.id.uuidString], repository: repository)
try check(detail["reference"] != nil && detail["bibtex"] != nil, "CLI explicit stable target")
let exported = output.appendingPathComponent("output.bib")
_ = try ReferenceCLI.response(["export", "--output", exported.path], repository: repository)
try check(try ReferenceBibTeX.parse(String(contentsOf: exported, encoding: .utf8)).count == countBefore - 1, "CLI export excludes Trash")
rejects("Export refuses overwrite") { _ = try ReferenceCLI.response(["export", "--output", exported.path], repository: repository) }
rejects("CLI invalid limit") { _ = try ReferenceCLI.response(["list", "--limit", "oops"], repository: repository) }
rejects("CLI invalid UUID") { _ = try ReferenceCLI.response(["show", "--id", "wrong"], repository: repository) }
let catalogue = root.appendingPathComponent("library.json"), safeBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
try Data("broken catalogue".utf8).write(to: catalogue)
rejects("Corrupt catalogue") { _ = try repository.add([ReferenceRecord()]) }
try check(try String(contentsOf: catalogue, encoding: .utf8) == "broken catalogue", "Never replace a corrupt catalogue with empty state")
try safeBytes.write(to: catalogue, options: .atomic)
let relationRepository = ReferenceRepository(root: output.appendingPathComponent("relations"), keyRule: .surnameYearWord)
let relations = try relationRepository.add(ReferenceBibTeX.parse("@proceedings{parent,title={Collected Works},author={Smith, Jane},year={2026}} @inproceedings{child,title={A Paper},author={Jones, Alice},year={2026},crossref={parent}}"))
let parent = relations[0], child = relations[1]
try check(child.fields["crossref"] == parent.key, "Imported internal crossrefs follow generated keys")
_ = try relationRepository.regenerate(id: parent.id, expected: parent.revision, rule: .surnameYearTwoWords)
let parentAfter = try relationRepository.records().first { $0.id == parent.id }!
let childAfter = try relationRepository.records().first { $0.id == child.id }!
try check(childAfter.fields["crossref"] == parentAfter.key, "Regeneration updates internal crossrefs")
try check(childAfter.revision != child.revision, "Updated crossref changes revision")
let lockPath = root.appendingPathComponent("library.lock").path
let lockFD = Darwin.open(lockPath, O_RDWR)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fatalError("Lock fixture") }
rejects("Concurrent catalogue writer") { try repository.trash(current.id) }
flock(lockFD, LOCK_UN); Darwin.close(lockFD)
try check(try repository.records().first { $0.id == current.id }?.trashed == nil, "Busy writer leaves data unchanged")
let model = MainActor.assumeIsolated { ReferenceModel(repository: ReferenceRepository(root: output.appendingPathComponent("model"), keyRule: .surnameYearWord)) }
func drainModel() throws {
    let deadline = Date().addingTimeInterval(10)
    while MainActor.assumeIsolated({ model.busy }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try check(!MainActor.assumeIsolated { model.busy }, "Model operation completes")
}
var manual = ReferenceRecord(); manual.fields = ["title": "Manual entry", "author": "Example, Jane", "year": "2026"]
var callback = false
MainActor.assumeIsolated { model.save(manual, existing: false) { callback = true } }
try drainModel()
try check(callback, "Manual save completion fires only after persistence")
try check(MainActor.assumeIsolated { model.records.first?.title } == "Manual entry", "Model reloads manually saved reference")
try check(MainActor.assumeIsolated { model.selection?.key } == "Example_2026_Manual", "Manual entry selected with preset key")
print("Passed \(checks) Reference checks. Synthetic fixtures: \(output.path)")

let library = try repository.addLibrary("Research")
let renameHistory = ReferenceRepository.History()
let renameRepo = ReferenceRepository(root: output.appendingPathComponent("library-renaming"), history: renameHistory)
let renameLibrary = try renameRepo.addLibrary("Research")
let renameCollection = try renameRepo.addLibrary("Notes", parentID: renameLibrary.id)
let renameRecord = try renameRepo.add([ReferenceRecord(fields: ["title": "Keep the reference"])], libraryID: renameCollection.id)[0]
let beforeLibraryRename = try renameRepo.records()
try renameRepo.renameLibrary(renameLibrary.id, to: "  Reading  ", expectedName: "Research")
try check(try renameRepo.libraries().first { $0.id == renameLibrary.id }?.name == "Reading", "Library rename trims the name and preserves its identity")
try check(try renameRepo.records() == beforeLibraryRename && renameRepo.libraries().first { $0.id == renameCollection.id }?.parentID == renameLibrary.id, "Library rename preserves references and child membership")
try renameRepo.undo()
try check(try renameRepo.libraries().first { $0.id == renameLibrary.id }?.name == "Research", "Library rename can be undone")
try renameRepo.undo(redo: true)
try check(try renameRepo.libraries().first { $0.id == renameLibrary.id }?.name == "Reading", "Library rename can be redone")
try renameRepo.renameLibrary(renameCollection.id, to: "Drafts", expectedName: "Notes")
try check(try renameRepo.records().first?.collectionID == renameCollection.id && renameRepo.records().first?.id == renameRecord.id, "Collection rename preserves reference membership")
rejects("Library rename rejects an empty name") { try renameRepo.renameLibrary(renameLibrary.id, to: " \n ") }
rejects("Library rename rejects overlong names") { try renameRepo.renameLibrary(renameLibrary.id, to: String(repeating: "x", count: 81)) }
rejects("Library rename rejects a sibling name collision") { try renameRepo.renameLibrary(renameLibrary.id, to: "MY LIBRARY") }
rejects("A stale name editor cannot overwrite a later rename") { try renameRepo.renameLibrary(renameLibrary.id, to: "Stale", expectedName: "Research") }
let secondRenameCollection = try renameRepo.addLibrary("Other", parentID: renameLibrary.id)
rejects("Collection rename rejects a sibling name collision") { try renameRepo.renameLibrary(secondRenameCollection.id, to: "drafts") }
try renameRepo.renameLibrary(renameLibrary.id, to: "READING", expectedName: "Reading")
try check(try renameRepo.libraries().first { $0.id == renameLibrary.id }?.name == "READING", "An item may change the case of its own name")
try renameRepo.deleteLibrary(secondRenameCollection.id)
rejects("Trashed collections cannot be renamed") { try renameRepo.renameLibrary(secondRenameCollection.id, to: "Unavailable") }
let readOnlyRenameRepo = ReferenceRepository(root: renameRepo.root, readOnly: true)
rejects("Read-only catalogues reject library rename") { try readOnlyRenameRepo.renameLibrary(renameLibrary.id, to: "Forbidden") }
try check(try repository.libraries().count == 2, "Legacy catalogue gains a second library")
let copy = try repository.duplicate(attached.id, to: library.id)
try check(copy.attachments == (try repository.records().first { $0.id == attached.id }!).attachments, "Cross-library copy shares managed PDF")
var renamedCopy = copy; renamedCopy.fields["title"] = "Independent metadata"
_ = try repository.update(renamedCopy, expected: copy.revision)
try check(try repository.records().first { $0.id == attached.id }?.title != "Independent metadata", "Cross-library metadata remains independent")
try repository.reorderLibrary(library.id, before: ReferenceLibrary.primaryID)
try check(try repository.libraries().first?.id == library.id, "Library order persists")
let libraryList = try ReferenceCLI.response(["libraries"], repository: repository)
try check((libraryList["libraries"] as? [[String: Any]])?.count == 2, "CLI lists libraries")
let scoped = try ReferenceCLI.response(["list", "--library", library.id.uuidString], repository: repository)
try check(scoped["total"] as? Int == 1, "CLI scopes reference listing")
let groups = ReferenceDuplicates.lookup(try repository.records())
try check(groups[copy.id]?.contains(attached.id) == true, "Shared PDF identifies duplicates across libraries")
let chainAttachments = (0..<64).map { ReferenceAttachment(name: "fixture.pdf", sha256: String(format: "%064x", $0), bytes: 100) }
var chainRecords = chainAttachments.map { ReferenceRecord(attachments: [$0]) }
for index in 1..<chainAttachments.count { chainRecords.append(ReferenceRecord(attachments: [chainAttachments[0], chainAttachments[index]])) }
var trashedChain = ReferenceRecord(attachments: [chainAttachments[0]]); trashedChain.trashed = Date()
let chainGroups = ReferenceDuplicates.lookup(chainRecords + [trashedChain])
try check(chainRecords.allSatisfy { chainGroups[$0.id] == chainRecords.map(\.id) }, "Transitive duplicate chains preserve all members and their original order")
try check(chainGroups[trashedChain.id] == nil, "Duplicate chains exclude trashed records")
let samePDF = try repository.importFiles([pdfURL], libraryID: library.id).first!
try check(samePDF.attachments.first?.id == copy.attachments.first?.id, "Repeated PDF import reuses stored bytes")
let snapshots = try repository.records().filter { groups[copy.id]?.contains($0.id) == true }
try repository.merge(snapshots, preferred: attached.id, alignMetadata: false)
rejects("Stale duplicate review") { try repository.merge(snapshots, preferred: attached.id, alignMetadata: false) }
try check(try repository.records().contains { $0.id == copy.id && $0.trashed == nil }, "Merge keeps membership in other libraries")
let currentGroup = ReferenceDuplicates.lookup(try repository.records())[samePDF.id]!
let currentSnapshots = try repository.records().filter { currentGroup.contains($0.id) }
try repository.merge(currentSnapshots, preferred: attached.id, alignMetadata: true)
try check(try repository.records().filter { $0.library == library.id }.count == 1, "Merge removes same-library extras without adding Trash entries")
try check(ReferenceMetadata.rows(copy).contains { $0.label == "Date added" }, "Metadata table includes date added")
var rare = ReferenceRecord(); rare.type = "phdthesis"
try check(ReferenceKind.classify(rare) == .other, "Uncommon imported types use Other")
try check(ReferenceKind.newspaper.applying(to: rare).fields["entrysubtype"] == "newspaper", "Newspaper keeps BibTeX subtype")
let beforeDelete = try repository.records().first { $0.id == attached.id }!
try repository.deleteLibrary(library.id)
try check(try repository.libraries().filter { $0.trashed == nil }.count == 1, "Library deletion moves library to Trash")
try check(FileManager.default.fileExists(atPath: repository.attachmentURL(beforeDelete.attachments[0]).path), "Library deletion preserves shared PDF")
try check(try repository.records().contains { $0.id == attached.id }, "Library deletion preserves other-library metadata")
try check(try ReferenceBibTeX.parse(ReferenceBibTeX.export([beforeDelete])).count == 1, "Selected export remains valid BibTeX")
print("Passed \(checks) Reference checks including library sharing and merge.")
var secondManual = manual; secondManual.id = UUID(); secondManual.fields["title"] = "Second entry"
MainActor.assumeIsolated { model.save(secondManual, existing: false) }
try drainModel()
try check(MainActor.assumeIsolated {
    let ids = model.items.map(\.id)
    model.select(ids[0], extending: false, range: false)
    model.select(ids[1], extending: true, range: false)
    return model.selectedIDs.count == 2 && model.contextRecords(model.items[0]).count == 2
}, "Command selection exports the selected group")
try check(MainActor.assumeIsolated {
    let ids = model.items.map(\.id)
    model.select(ids[0], extending: false, range: false)
    model.select(ids[1], extending: false, range: true)
    return model.selectedIDs.count == 2
}, "Shift selection spans the visible range")
print("Passed \(checks) Reference checks including multiple selection.")

try repository.restoreLibrary(library.id)
try check(try repository.libraries().first { $0.id == library.id }?.trashed == nil, "Library restore recovers metadata")
let collection = try repository.addLibrary("KTH", parentID: library.id)
let collectionRecord = try repository.add([manual], libraryID: collection.id).first!
try check(collectionRecord.library == library.id && collectionRecord.collectionID == collection.id, "Collection belongs to its library")
var parentDraft = manual; parentDraft.id = UUID()
let parentRecord = try repository.add([parentDraft], libraryID: library.id).first!
try check(parentRecord.key != collectionRecord.key, "Collections share the parent key namespace")
rejects("Third hierarchy level") { _ = try repository.addLibrary("Too deep", parentID: collection.id) }
try repository.deleteLibrary(collection.id)
try check(try repository.records().contains { $0.id == collectionRecord.id }, "Deleting a collection preserves data in Trash")
rejects("Write to deleted collection") { _ = try repository.add([manual], libraryID: collection.id) }
try repository.emptyTrash()
try check(try !repository.records().contains { $0.id == collectionRecord.id }, "Empty Trash removes collection metadata")
try check(try repository.records().contains { $0.id == parentRecord.id }, "Empty Trash preserves active metadata")
try check(FileManager.default.fileExists(atPath: repository.attachmentURL(beforeDelete.attachments[0]).path), "Empty Trash preserves active shared PDF")
var withAbstract = manual; withAbstract.key = "Example"; withAbstract.fields["abstract"] = "Stored abstract"
try check(try !ReferenceExport.bibtex([withAbstract], includeAbstract: false).contains("abstract ="), "Abstract excluded from export when off")
try check(try ReferenceExport.bibtex([withAbstract], includeAbstract: true).contains("abstract ="), "Abstract included only when enabled")
try check(withAbstract.fields["abstract"] == "Stored abstract", "Export does not erase stored abstract")
try check(ReferenceMetadata.rows(withAbstract).last?.id == "abstract", "Abstract follows the compact metadata rows for its collapsed disclosure")
try check(ReferenceColumn.visible("publisher,year").contains(.title), "Title column always stays visible")
try check(ReferenceColumn.visible("title,unknown,publisher") == [.title,.publisher], "Column preferences ignore unknown values")
print("Passed \(checks) Reference checks with collections, Trash and abstract policy.")

let settingsSuite = "reference-fixture-" + UUID().uuidString
let settingsStore = UserDefaults(suiteName: settingsSuite)!
defer { settingsStore.removePersistentDomain(forName: settingsSuite) }
settingsStore.set("private-token", forKey: "overleaf.token")
settingsStore.set("/private/project", forKey: "reader.recentDocuments")
settingsStore.set("title,publisher,year", forKey: ReferenceColumn.preference)
let portable = PortableSettings.snapshot(settingsStore)
try check(portable.preferences["overleaf.token"] == nil && portable.preferences["reader.recentDocuments"] == nil, "Portable settings excludes accounts and file paths")
try PortableSettings.apply(portable, to: settingsStore)
try check(settingsStore.string(forKey: ReferenceColumn.preference) == "title,publisher,year", "Portable settings round trip")
rejects("Portable settings rejects unknown keys") { try PortableSettings.apply(.init(preferences: ["overleaf.token": .string("bad")]), to: settingsStore) }
try check(WorkspaceLayout.referenceSide(1400) * 2 < 1400 * 0.45, "Reference reserves most width for the central list")
try check(WorkspaceLayout.results(1400) > WorkspaceLayout.outline(1400), "Search results are wider than outlines")
print("Passed \(checks) Reference and portable settings checks.")
let uniqueLibrary = try repository.addLibrary("Disposable fixture")
let uniquePDF = PDFDocument(data: pdfBytes)!
uniquePDF.insert(PDFPage(), at: uniquePDF.pageCount)
let uniqueURL = output.appendingPathComponent("unique.pdf")
try uniquePDF.dataRepresentation()!.write(to: uniqueURL)
let uniqueRecord = try repository.importFiles([uniqueURL], libraryID: uniqueLibrary.id).first!
let uniqueAttachment = repository.attachmentURL(uniqueRecord.attachments[0])
try repository.deleteLibrary(uniqueLibrary.id)
try check(FileManager.default.fileExists(atPath: uniqueAttachment.path), "Library Trash retains unshared PDFs before confirmation")
try repository.emptyTrash()
try check(!FileManager.default.fileExists(atPath: uniqueAttachment.path), "Empty Trash removes an unshared PDF")
print("Passed \(checks) checks including unshared PDF removal.")

let hiddenCollection = try relationRepository.addLibrary("Hidden collection", parentID: ReferenceLibrary.primaryID)
try relationRepository.move(childAfter.id, to: hiddenCollection.id)
try relationRepository.deleteLibrary(hiddenCollection.id)
let hiddenBefore = try relationRepository.records().first { $0.id == childAfter.id }!
let liveParent = try relationRepository.records().first { $0.id == parentAfter.id }!
_ = try relationRepository.regenerate(id: liveParent.id, expected: liveParent.revision, rule: .surnameYear)
try check(try relationRepository.records().first { $0.id == hiddenBefore.id } == hiddenBefore, "Citation-key changes leave trashed collection records untouched")
print("Passed \(checks) checks including trashed collection citation links.")

// Clicking another reference while saving must preserve that destination.
let beforeInline = MainActor.assumeIsolated { model.records.first { $0.id == manual.id }! }
var inlineDraft = beforeInline
inlineDraft.fields["volume"] = "47"
let destinationID = MainActor.assumeIsolated { model.records.first { $0.id != manual.id }!.id }
MainActor.assumeIsolated {
    model.load()
    model.save(inlineDraft, existing: true, selectAfterSave: false)
    model.select(destinationID, extending: false, range: false)
}
try drainModel()
try check(MainActor.assumeIsolated { model.selection?.id == destinationID && model.selectedIDs == [destinationID] }, "Inline save preserves the clicked reference")
try check(try model.repository.records().first { $0.id == manual.id }?.fields["volume"] == "47", "Inline edit waits for an existing operation instead of disappearing")
var staleRejected = false
var staleDraft = beforeInline
staleDraft.fields["volume"] = "99"
MainActor.assumeIsolated { model.save(staleDraft, existing: true, selectAfterSave: false, onFailure: { staleRejected = true }) }
try drainModel()
try check(staleRejected && (try model.repository.records().first { $0.id == manual.id }?.fields["volume"]) == "47", "Stale inline edit reports failure and preserves saved data")
print("Passed \(checks) checks including click-away saves.")

let caseEntries = try ReferenceBibTeX.parse("@book{UP,title={Upper}} @book{up,title={Lower}} @inbook{child,title={Child},crossref={UP}} @inbook{other,title={Other},crossref={up}}")
let caseRepo = ReferenceRepository(root: output.appendingPathComponent("case-keys"), keyRule: .surnameYear)
let caseAdded = try caseRepo.add(caseEntries)
try check(caseAdded[2].fields["crossref"] == caseAdded[0].key && caseAdded[3].fields["crossref"] == caseAdded[1].key, "Case-distinct source keys retain their own parent links")
try check(Set(caseAdded.map { $0.key.lowercased() }).count == 4, "Imported records receive unique managed keys")
try check(try ReferenceBibTeX.parse(ReferenceBibTeX.export(caseEntries)).map(\.key) == caseEntries.map(\.key), "Case-distinct citation keys round trip")
if CommandLine.arguments.count > 2 {
    let source = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    let entries = try ReferenceBibTeX.parse(source)
    let batchRepo = ReferenceRepository(root: output.appendingPathComponent("external-bibliography"), keyRule: .surnameYearWord)
    let imported = try batchRepo.add(entries)
    try check(imported.count == entries.count && imported.count > 1, "Whole supplied bibliography imports atomically")
    try check(zip(imported, entries).allSatisfy { $0.originalKey == $1.key && $0.fields == $1.fields }, "Supplied bibliography preserves original keys and all metadata")
    try check(try ReferenceBibTeX.parse(ReferenceBibTeX.export(imported)).map(\.fields) == imported.map(\.fields), "Supplied bibliography exports and reparses without field loss")
    print("Supplied bibliography:", entries.count, "entries imported and round-tripped")
}
print("Passed \(checks) checks including case-distinct bibliography keys.")

var untidy = ReferenceRecord()
untidy.fields = ["title": "  A   local\nreference  ", "author": "  Doe, Jane ", "doi": "https://doi.org/10.1234/EXAMPLE", "note": "Keep   my notes", "abstract": "Keep   the abstract"]
let cleanupRepo = ReferenceRepository(root: output.appendingPathComponent("cleanup"), keyRule: .surnameYearWord)
let untidyAdded = try cleanupRepo.add([untidy])[0]
let proposals = try ReferenceCleanup.proposals([untidyAdded], repository: cleanupRepo)
try check(proposals.count == 1 && proposals[0].after.fields["title"] == "A local reference", "Cleanup proposes bounded formatting changes")
try check(try cleanupRepo.records()[0].fields == untidy.fields, "Preparing cleanup changes nothing")
try cleanupRepo.applyCleanup(proposals)
let tidy = try cleanupRepo.records()[0]
try check(tidy.key == untidyAdded.key && tidy.fields["doi"] == "10.1234/example", "Approved cleanup preserves keys and normalises DOI wrappers")
try check(tidy.fields["note"] == untidy.fields["note"] && tidy.fields["abstract"] == untidy.fields["abstract"], "Cleanup preserves notes and abstracts verbatim")
rejects("Stale cleanup") { try cleanupRepo.applyCleanup(proposals) }
var doiLink = ReferenceRecord(); doiLink.fields = ["title": "A different spelling", "url": "http://dx.doi.org/10.1234/EXAMPLE"]
try check(ReferenceDuplicates.lookup([tidy, doiLink])[tidy.id]?.contains(doiLink.id) == true, "DOI links identify duplicate candidates despite metadata differences")
var abbreviated = ReferenceRecord(); abbreviated.fields = ["title": #"A {\textit{local}} reference"#, "author": "J. Doe", "year": "2026"]
var fullName = tidy; fullName.fields["year"] = "2026"
try check(ReferenceDuplicates.lookup([fullName, abbreviated])[fullName.id]?.contains(abbreviated.id) == true, "Formatting and initialised authors can be reviewed as duplicate candidates")
let pdfData = NSMutableData()
var pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &pageBox, nil)!
pdfContext.beginPDFPage(nil)
for (text, size, y) in [("A careful study of reference metadata", 22.0, 700.0), ("https://doi.org/10.1234/PDF-EVIDENCE", 10.0, 650.0), ("Body text for the local extraction check.", 10.0, 620.0)] {
    pdfContext.textPosition = CGPoint(x: 50, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])), pdfContext)
}
pdfContext.endPDFPage(); pdfContext.closePDF()
let metadataPDF = PDFDocument(data: pdfData as Data)!
metadataPDF.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Untitled", PDFDocumentAttribute.authorAttribute: "Doe, Jane"]
let extracted = ReferencePDFMetadata.fields(metadataPDF, fallback: "uploaded-paper")
try check(extracted["doi"] == "10.1234/pdf-evidence" && extracted["author"] == "Doe, Jane", "PDF import reads embedded authors and first-page DOI evidence")
try check(extracted["title"] == "A careful study of reference metadata", "PDF import can recover a prominent title when embedded metadata is generic")
try check(extracted["year"] == nil, "PDF dates and arbitrary years are not guessed as publication years")
print("Passed \(checks) Reference checks including local cleanup and PDF metadata")

let formattedTitle = #"A {{DNS}} Evaluation of {\textit{Three}} Models with L{\'e}on and \alpha"#
try check(ReferenceText.display(formattedTitle) == "A DNS Evaluation of Three Models with Léon and α", "BibTeX protection and formatting display as readable text")
try check(ReferenceText.display(#"Garc{\'i}a, M{\"u}ller and \v{S}imek \& Co."#) == "García, Müller and Šimek & Co.", "TeX accents and escaped symbols display correctly")
try check(ReferenceText.authors("{Research and Development Group} and Doe, Jane").count == 2, "Corporate authors keep their internal and")
try check(ReferenceText.shortAuthors("{Research and Development Group} and Doe, Jane") == "Research and Development Group et al.", "Author labels are compact without splitting organisations")
var readable = ReferenceRecord(); readable.fields = ["title": formattedTitle, "author": #"Garc{\'i}a, Ana and Doe, Jane"#]
let untouched = readable.fields
try check(ReferenceColumn.title.value(readable) == ReferenceText.display(formattedTitle) && ReferenceColumn.author.value(readable) == "García et al.", "Reference columns use readable title and compact authors")
try check(readable.fields == untouched && (try ReferenceBibTeX.parse(ReferenceBibTeX.export([readable]))[0].fields) == untouched, "Display formatting preserves exact BibTeX fields through export")
print("Passed \(checks) Reference checks including readable BibTeX labels")

try check(ReferenceText.display("for~Subgrid--Scale---Models") == "for Subgrid–Scale—Models", "TeX spacing and dashes render without source notation")
let displayCache = ReferenceTextCache(countLimit: 2, byteLimit: 64)
var displayComputations = 0
func cachedDisplay(_ source: String, kind: String = "display") -> [String] {
    displayCache.value(kind: kind, source: source) { displayComputations += 1; return [source.uppercased()] }
}
try check(cachedDisplay("alpha") == ["ALPHA"] && cachedDisplay("alpha") == ["ALPHA"] && displayComputations == 1, "Unchanged display strings reuse their parsed value")
_ = cachedDisplay("beta"); _ = cachedDisplay("alpha"); _ = cachedDisplay("gamma")
let beforeCachedHit = displayComputations
_ = cachedDisplay("alpha")
try check(displayComputations == beforeCachedHit, "Display cache promotes recently used strings")
_ = cachedDisplay("beta")
try check(displayComputations == beforeCachedHit + 1, "Display cache evicts the least recently used string")
_ = cachedDisplay("beta", kind: "authors")
try check(displayComputations == beforeCachedHit + 2, "Different display operations do not share incompatible values")
for i in 0..<100 { _ = cachedDisplay("field-\(i)") }
try check(displayCache.usage.count <= 2 && displayCache.usage.textBytes <= 64, "Display reuse respects item and text-byte limits")
let beforeOversized = displayCache.usage
_ = cachedDisplay(String(repeating: "x", count: 20_000))
try check(displayCache.usage.count == beforeOversized.count && displayCache.usage.textBytes == beforeOversized.textBytes, "Large metadata bypasses the display cache")
let parallelDisplayCache = ReferenceTextCache(countLimit: 8, byteLimit: 512)
DispatchQueue.concurrentPerform(iterations: 64) { i in
    let source = "field-\(i % 8)"
    precondition(parallelDisplayCache.value(kind: "display", source: source) { [source] } == [source])
}
try check(parallelDisplayCache.usage.count <= 8 && parallelDisplayCache.usage.textBytes <= 512, "Concurrent display preparation keeps the cache consistent and bounded")
print("Passed \(checks) Reference checks including display spacing")

var venue = ReferenceRecord(); venue.fields = ["journal": "{{Combustion}} and Flame", "publisher": "Elsevier"]
try check(ReferenceColumn.publication.value(venue) == "Combustion and Flame", "Venue column prefers the journal over its publisher")
venue.fields["journal"] = " "
try check(ReferenceColumn.publication.value(venue) == "Elsevier", "Venue column falls back to publisher when journal is blank")
venue.fields["booktitle"] = "Annual Conference"
try check(ReferenceColumn.publication.value(venue) == "Annual Conference", "Conference venue precedes publisher")
try check(ReferenceColumn.visible(ReferenceColumn.defaults) == [.title, .author, .publication, .year, .type], "Default columns include venue, year and Type")
try check(!ReferenceColumn.visible("title,author,year").contains(.publication), "Users can hide the venue column without it reappearing")
print("Passed \(checks) Reference checks including venue columns")

var formal = ReferenceRecord(); formal.type = "article"; formal.fields = ["title": "A study of reliable reference merging", "author": "Doe, Jane", "year": "2026", "journal": "Example Journal", "doi": "10.1234/published"]
var archive = ReferenceRecord(); archive.type = "unpublished"; archive.fields = ["title": "A STUDY OF RELIABLE REFERENCE MERGING", "author": "Doe, Jane", "year": "2025", "journal": "arXiv", "publisher": "arXiv", "doi": "10.1234/preprint", "eprint": "2501.00001"]
archive.attachments = [ReferenceAttachment(name: "archive.pdf", sha256: "fixture", bytes: 100)]
try check(ReferenceMergePlan.ranked([archive, formal]).first?.id == formal.id, "A PDF-bearing preprint does not outrank the published record")
try check(ReferenceDuplicates.lookup([archive, formal])[formal.id]?.contains(archive.id) == true, "A preprint and a matching publication within one year are review candidates")
let mergedFields = ReferenceMergePlan.fields([formal, archive], preferred: formal.id)
try check(mergedFields["publisher"] == nil && mergedFields["doi"] == "10.1234/published" && mergedFields["eprint"] == "2501.00001", "Preprint publication fields do not pollute the published metadata")
var complementary = formal; complementary.id = UUID(); complementary.fields["publisher"] = "Example Press"; complementary.fields["volume"] = "12"; complementary.fields["title"] = formal.fields["title"]?.uppercased()
let proposed = ReferenceMergePlan.fields([formal, complementary], preferred: complementary.id)
try check(proposed["title"] == formal.fields["title"] && proposed["publisher"] == "Example Press" && proposed["volume"] == "12", "Readable title and complementary publication details combine without changing facts")
let mergeRepo = ReferenceRepository(root: output.appendingPathComponent("ranked-merge"), keyRule: .surnameYearWord)
let formalAdded = try mergeRepo.addFetched(formal, pdf: nil, libraryID: ReferenceLibrary.primaryID)
let complementAdded = try mergeRepo.addFetched(complementary, pdf: pdfData as Data, libraryID: ReferenceLibrary.primaryID)
let resolved = ReferenceMergePlan.fields([formalAdded, complementAdded], preferred: formalAdded.id)
try mergeRepo.merge([formalAdded, complementAdded], preferred: formalAdded.id, alignMetadata: false, resolvedFields: resolved)
let kept = try mergeRepo.records().first { $0.id == formalAdded.id }!
try check(kept.fields["publisher"] == "Example Press" && kept.attachments.count == 1 && kept.key == formalAdded.key, "Reviewed merge keeps the preferred key, fills metadata and retains the other PDF")
try check(try !mergeRepo.records().contains { $0.id == complementAdded.id }, "Merged duplicate is removed from the catalogue")
try check(FileManager.default.fileExists(atPath: mergeRepo.attachmentURL(kept.attachments[0]).path), "Merged PDF remains available")
try check(!FileManager.default.fileExists(atPath: mergeRepo.root.appendingPathComponent("Recovery").path), "Merge does not create a persistent duplicate recovery copy")
let mergeHistory = ReferenceRepository.History()
let undoMergeRepo = mergeRepo.recordingHistory(mergeHistory)
let mergeCopy = try undoMergeRepo.duplicate(kept.id, to: ReferenceLibrary.primaryID)
try undoMergeRepo.merge([kept, mergeCopy], preferred: kept.id, alignMetadata: false)
try undoMergeRepo.undo()
try check(try undoMergeRepo.records().contains { $0.id == mergeCopy.id && $0.trashed == nil }, "Session Undo restores a merged duplicate")
try undoMergeRepo.undo(redo: true)
try check(try !undoMergeRepo.records().contains { $0.id == mergeCopy.id }, "Redo removes the duplicate without Trash")
let atomicBefore = try mergeRepo.records()
rejects("Invalid fetched PDF") { _ = try mergeRepo.addFetched(formal, pdf: Data("HTML paywall".utf8), libraryID: ReferenceLibrary.primaryID) }
try check(try mergeRepo.records() == atomicBefore, "A failed PDF import leaves no partial reference")
let crossrefFixture = Data(#"{"message":{"DOI":"10.1234/example","title":["A <i>careful</i> study &amp; review"],"type":"journal-article","author":[{"family":"Doe","given":"Jane"}],"container-title":["Example Journal"],"publisher":"Example Press","published-print":{"date-parts":[[2026,5]]},"volume":"12","issue":"3","page":"10-20"}}"#.utf8)
let fetched = try ReferencePaperLookup.parseCrossref(crossrefFixture, single: true)[0]
try check(fetched.fields["title"] == "A careful study & review" && fetched.fields["author"] == "Doe, Jane" && fetched.fields["year"] == "2026" && fetched.fields["journal"] == "Example Journal", "Crossref metadata maps names, dates and journal without markup leakage")
let oaFixture = Data(#"{"locations":[{"is_oa":false,"pdf_url":"https://closed.example.org/a.pdf"},{"is_oa":true,"version":"submittedVersion","pdf_url":"https://archive.example.org/a.pdf"},{"is_oa":true,"version":"publishedVersion","pdf_url":"https://journal.example.org/a.pdf"},{"is_oa":true,"pdf_url":"http://localhost/private.pdf"}]}"#.utf8)
let openURLs = try ReferencePaperLookup.parseOpenPDFs(oaFixture)
try check(openURLs.count == 2 && openURLs[0].host == "journal.example.org", "Only declared open HTTPS PDF locations are proposed, published version first")
try check(!ReferencePaperLookup.publicURL(URL(string: "https://127.0.0.1/file")!) && !ReferencePaperLookup.publicURL(URL(string: "https://user:secret@host.example/file")!), "Public PDF retrieval excludes local and credential-bearing URLs")
print("Passed \(checks) Reference checks including ranked merging and paper lookup")
let landing = Data(#"<head><meta content='/paper.pdf?download=1&amp;version=2' name='citation_pdf_url'></head><body>Ignored</body>"#.utf8)
try check(ReferencePaperLookup.landingPDFs(landing, base: URL(string: "https://journal.example.org/article")!).first?.absoluteString == "https://journal.example.org/paper.pdf?download=1&version=2", "Open landing-page citation metadata resolves a public PDF link")
try check(ReferencePaperLookup.landingPDFs(Data(#"<meta name='citation_pdf_url' content='file:///private/data.pdf'>"#.utf8), base: URL(string: "https://journal.example.org")!).isEmpty, "Landing-page metadata cannot trigger a local file read")
print("Passed \(checks) Reference checks including bounded public PDF discovery")
let collisionRepo = ReferenceRepository(root: output.appendingPathComponent("cross-library-merge"), keyRule: .surnameYearWord)
let canonical = try collisionRepo.add([formal])[0]
let secondLibrary = try collisionRepo.addLibrary("Independent library")
var newer = formal; newer.id = UUID(); newer.created = Date(timeIntervalSince1970: 2000); newer.fields["publisher"] = "Local library press"
var older = formal; older.id = UUID(); older.created = Date(timeIntervalSince1970: 1000); older.fields["publisher"] = "Local library press"
let firstCopy = try collisionRepo.add([newer], libraryID: secondLibrary.id)[0]
let olderCopy = try collisionRepo.add([older], libraryID: secondLibrary.id)[0]
try collisionRepo.merge([canonical, firstCopy, olderCopy], preferred: canonical.id, alignMetadata: false)
let collisionRecords = try collisionRepo.records()
try check(collisionRecords.filter { $0.library == secondLibrary.id && $0.trashed == nil }.count == 1 && Set(collisionRecords.map { $0.library.uuidString + $0.key.lowercased() }).count == collisionRecords.count, "Cross-library merge preserves key uniqueness including recoverable Trash entries")
try check(collisionRecords.first { $0.id == olderCopy.id }?.fields["publisher"] == "Local library press", "Other library metadata stays independent unless alignment is chosen")
print("Passed \(checks) Reference checks including cross-library merge collisions")

let harbourRepo = ReferenceRepository(root: output.appendingPathComponent("harbour"), keyRule: .surnameYearWord)
var harbourDraft = ReferenceRecord(); harbourDraft.fields = ["title": "Curated title", "doi": "https://doi.org/10.1234/PDF-EVIDENCE", "year": "2026", "publisher": "Curated press"]
let harbourBase = try harbourRepo.add([harbourDraft])[0]
let harbourPDF = output.appendingPathComponent("harbour.pdf"); try metadataPDF.dataRepresentation()!.write(to: harbourPDF)
let harbourAttached = try harbourRepo.importFiles([harbourPDF], matchingExisting: true)[0]
try check(harbourAttached.id == harbourBase.id && harbourAttached.attachments.count == 1, "Harbour attaches an unambiguous PDF DOI match instead of making a copy")
try check(harbourAttached.title == "Curated title" && harbourAttached.key == harbourBase.key && harbourAttached.fields["publisher"] == "Curated press" && harbourAttached.authors == "Doe, Jane", "Matched attachment fills only missing fields and retains curated metadata and key")
let harbourAgain = try harbourRepo.importFiles([harbourPDF], matchingExisting: true)[0]
try check(harbourAgain.id == harbourBase.id && harbourAgain.attachments.count == 1 && (try harbourRepo.records()).count == 1, "Repeated Harbour PDF drops are idempotent")
let otherHarbour = try harbourRepo.addLibrary("Other library")
let independentHarbour = try harbourRepo.importFiles([harbourPDF], libraryID: otherHarbour.id, matchingExisting: true)[0]
try check(independentHarbour.library == otherHarbour.id && independentHarbour.id != harbourBase.id && independentHarbour.attachments[0].id == harbourAttached.attachments[0].id, "Harbour respects the selected library while sharing PDF bytes")
let ambiguousRepo = ReferenceRepository(root: output.appendingPathComponent("harbour-ambiguous"), keyRule: .surnameYearWord)
var ambiguousDraft = harbourDraft; ambiguousDraft.id = UUID()
_ = try ambiguousRepo.add([harbourDraft, ambiguousDraft])
let ambiguousPDF = try ambiguousRepo.importFiles([harbourPDF], matchingExisting: true)[0]
try check((try ambiguousRepo.records()).count == 3 && ambiguousPDF.attachments.count == 1, "Ambiguous DOI matches stay separate for reviewed cleanup")
print("Passed \(checks) Reference checks including Harbour matching")

try check(ReferenceMetadata.rows(harbourAgain).first?.id == "key", "Citation key leads the metadata inspector")
try check(ReferenceKeyRule.surnameYearWord.example == "Toy_2026_Filter", "Key preset uses the Toy example")
let beforeDetach = try harbourRepo.records().first { $0.id == harbourBase.id }!
let detached = try harbourRepo.removeAttachments(Set(beforeDetach.attachments.map(\.id)), from: beforeDetach.id, expected: beforeDetach.revision)
try check(detached.attachments.isEmpty && detached.fields == beforeDetach.fields && detached.key == beforeDetach.key, "Removing attachments preserves metadata and citation key")
rejects("Stale attachment removal") { _ = try harbourRepo.removeAttachments(Set(beforeDetach.attachments.map(\.id)), from: beforeDetach.id, expected: beforeDetach.revision) }
try harbourRepo.emptyTrash()
try check(FileManager.default.fileExists(atPath: harbourRepo.attachmentURL(independentHarbour.attachments[0]).path), "Attachment removal and Empty Trash preserve another library's shared PDF")
let otherDetached = try harbourRepo.removeAttachments(Set(independentHarbour.attachments.map(\.id)), from: independentHarbour.id, expected: independentHarbour.revision)
try check(FileManager.default.fileExists(atPath: harbourRepo.attachmentURL(independentHarbour.attachments[0]).path), "Unshared attachment bytes remain until explicit Empty Trash")
try harbourRepo.emptyTrash()
try check(!FileManager.default.fileExists(atPath: harbourRepo.attachmentURL(independentHarbour.attachments[0]).path) && FileManager.default.fileExists(atPath: harbourPDF.path), "Explicit purge removes unshared managed bytes and retains the original PDF")
let detachManyRepo = ReferenceRepository(root: output.appendingPathComponent("detach-many"))
let detachBase = try detachManyRepo.add([ReferenceRecord()])[0]
let detachOne = try detachManyRepo.importFiles([pdfURL], attachingTo: detachBase.id, expected: detachBase.revision)[0]
let detachTwo = try detachManyRepo.importFiles([uniqueURL], attachingTo: detachOne.id, expected: detachOne.revision)[0]
rejects("Invalid attachment selection is atomic") { _ = try detachManyRepo.removeAttachments([UUID()], from: detachTwo.id, expected: detachTwo.revision) }
let detachAll = try detachManyRepo.removeAttachments(Set(detachTwo.attachments.map(\.id)), from: detachTwo.id, expected: detachTwo.revision)
try check(detachTwo.attachments.count == 2 && detachAll.attachments.isEmpty, "Several selected attachments are removed together")
print("Passed \(checks) Reference checks including attachment removal")

let removalLibrary = try detachManyRepo.addLibrary("To Trash")
let removalRecord = try detachManyRepo.importFiles([pdfURL], libraryID: removalLibrary.id)[0]
try detachManyRepo.deleteLibrary(removalLibrary.id)
rejects("A library moved to Trash cannot lose attachments through a stale sheet") { _ = try detachManyRepo.removeAttachments(Set(removalRecord.attachments.map(\.id)), from: removalRecord.id, expected: removalRecord.revision) }
print("Passed \(checks) Reference checks including stale attachment sheets")

let selectionRepo = ReferenceRepository(root: output.appendingPathComponent("selected-merge"))
var selectionA = ReferenceRecord(); selectionA.fields = ["title": "A candidate paper", "author": "Doe, Jane", "year": "2026", "doi": "10.1234/selected"]
var selectionB = selectionA; selectionB.id = UUID(); selectionB.fields["publisher"] = "Example Press"
var selectionC = selectionA; selectionC.id = UUID(); selectionC.fields = ["title": "A different paper", "doi": "10.1234/unrelated"]
let selectionRows = try selectionRepo.add([selectionA, selectionB, selectionC])
let selectionModel = MainActor.assumeIsolated { ReferenceModel(repository: selectionRepo) }
MainActor.assumeIsolated { selectionModel.load() }
let selectionDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ selectionModel.busy }) && Date() < selectionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
try check(MainActor.assumeIsolated { !selectionModel.busy && selectionModel.libraryCounts[ReferenceLibrary.primaryID] == 3 }, "Library counts are rebuilt from one loaded snapshot")
MainActor.assumeIsolated { selectionModel.selectedIDs = [selectionRows[0].id, selectionRows[1].id] }
try check(MainActor.assumeIsolated { selectionModel.selectedDuplicates(selectionRows[0])?.count == 2 }, "Selected duplicate rows can share the existing merge review")
MainActor.assumeIsolated { selectionModel.selectedIDs.insert(selectionRows[2].id) }
try check(MainActor.assumeIsolated { selectionModel.selectedDuplicates(selectionRows[0]) == nil }, "An unrelated selected row cannot silently join a merge")
let coherent = try selectionRepo.snapshot()
try check(coherent.records.count == 3 && coherent.libraries.count == 1, "Repository exposes one coherent catalogue snapshot")
let selectionCollection = try selectionRepo.addLibrary("Collection", parentID: ReferenceLibrary.primaryID)
let discovered = try ReferenceCLI.response(["libraries"], repository: selectionRepo)["libraries"] as! [[String: Any]]
try check(discovered.first { $0["id"] as? String == selectionCollection.id.uuidString }?["parentID"] as? String == ReferenceLibrary.primaryID.uuidString, "CLI exposes collection parent identity")
var longSummary = ReferenceRecord(); longSummary.fields = ["title": String(repeating: "t", count: 2000), "author": String(repeating: "a", count: 800), "journal": String(repeating: "j", count: 800)]
_ = try selectionRepo.add([longSummary])
let boundedRows = try ReferenceCLI.response(["list", "--query", String(repeating: "t", count: 30)], repository: selectionRepo)["references"] as! [[String: Any]]
try check((boundedRows[0]["title"] as? String)?.count == 1000 && (boundedRows[0]["authors"] as? String)?.count == 500 && boundedRows[0]["summaryTruncated"] as? Bool == true, "CLI summaries have explicit per-field bounds")
print("Passed \(checks) Reference checks including selected merging and CLI snapshots")

let writeRepo = ReferenceRepository(root: output.appendingPathComponent("cli-write"))
let writeFile = output.appendingPathComponent("cli-write.bib")
try Data("@article{source,title={Before CLI edit},author={Doe, Jane},year={2026}}".utf8).write(to: writeFile)
let importedCLI = try ReferenceCLI.response(["import", "--library", ReferenceLibrary.primaryID.uuidString, "--source-file", writeFile.path], repository: writeRepo)
try check((importedCLI["references"] as? [[String: String]])?.count == 1, "CLI imports into an explicit destination library")
let beforeCLI = try writeRepo.records()[0]
try Data("@article{ignored,title={After CLI edit},author={Doe, Jane},year={2026}}".utf8).write(to: writeFile)
_ = try ReferenceCLI.response(["update", "--id", beforeCLI.id.uuidString, "--expected-revision", beforeCLI.revision.uuidString, "--source-file", writeFile.path], repository: writeRepo)
let updatedCLI = try writeRepo.records()[0]
try check(updatedCLI.title == "After CLI edit" && updatedCLI.key == beforeCLI.key, "Revision-checked CLI metadata updates retain the citation key")
rejects("A stale CLI update cannot overwrite a newer revision") { _ = try ReferenceCLI.response(["update", "--id", beforeCLI.id.uuidString, "--expected-revision", beforeCLI.revision.uuidString, "--source-file", writeFile.path], repository: writeRepo) }
_ = try ReferenceCLI.response(["attach", "--id", updatedCLI.id.uuidString, "--expected-revision", updatedCLI.revision.uuidString, "--source-file", pdfURL.path], repository: writeRepo)
let attachedCLI = try writeRepo.records()[0]
try check(attachedCLI.attachments.count == 1, "CLI attachment writes use the shared managed repository")
_ = try ReferenceCLI.response(["detach", "--id", attachedCLI.id.uuidString, "--expected-revision", attachedCLI.revision.uuidString, "--attachment", attachedCLI.attachments[0].id.uuidString], repository: writeRepo)
let detachedCLI = try writeRepo.records()[0]
try check(detachedCLI.attachments.isEmpty && FileManager.default.fileExists(atPath: writeRepo.attachmentURL(attachedCLI.attachments[0]).path), "CLI detach never immediately purges managed PDF bytes")
_ = try ReferenceCLI.response(["trash", "--id", detachedCLI.id.uuidString, "--expected-revision", detachedCLI.revision.uuidString], repository: writeRepo)
let trashedCLI = try writeRepo.records()[0]
try check(trashedCLI.trashed != nil, "CLI deletion is recoverable Trash")
rejects("A repeated stale Trash command fails") { _ = try ReferenceCLI.response(["trash", "--id", detachedCLI.id.uuidString, "--expected-revision", detachedCLI.revision.uuidString], repository: writeRepo) }
_ = try ReferenceCLI.response(["restore", "--id", trashedCLI.id.uuidString, "--expected-revision", trashedCLI.revision.uuidString], repository: writeRepo)
try check(try writeRepo.records()[0].trashed == nil, "CLI restores a revision-checked record")
let watchingModel = MainActor.assumeIsolated { ReferenceModel(repository: writeRepo) }
let watchingTask = Task { @MainActor in await watchingModel.watch() }
let watchDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ watchingModel.records.isEmpty }) && Date() < watchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
let external = try writeRepo.add([selectionC])[0]
let refreshDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ !watchingModel.records.contains { $0.id == external.id } }) && Date() < refreshDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
try check(MainActor.assumeIsolated { watchingModel.records.contains { $0.id == external.id } }, "Native Reference model observes external CLI catalogue changes")
watchingTask.cancel()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
let settlingDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ watchingModel.busy }) && Date() < settlingDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
var reentryPublications = 0, reentryBusyChanges = 0
let recordsObservation = MainActor.assumeIsolated { watchingModel.$records.dropFirst().sink { _ in reentryPublications += 1 } }
let busyObservation = MainActor.assumeIsolated { watchingModel.$busy.dropFirst().sink { _ in reentryBusyChanges += 1 } }
let reentryWatch = Task { @MainActor in await watchingModel.watch() }
RunLoop.current.run(until: Date().addingTimeInterval(0.25))
try check(reentryPublications == 0 && reentryBusyChanges == 0, "Reentering an unchanged library does not reload or disable its list")
var afterReentry = selectionC; afterReentry.id = UUID(); afterReentry.fields["title"] = "An external edit after reentry"
let changedAfterReentry = try writeRepo.add([afterReentry])[0]
let reentryDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ !watchingModel.records.contains { $0.id == changedAfterReentry.id } }) && Date() < reentryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
try check(MainActor.assumeIsolated { watchingModel.records.contains { $0.id == changedAfterReentry.id } }, "A resumed watcher still refreshes changed metadata")
reentryWatch.cancel(); recordsObservation.cancel(); busyObservation.cancel()
print("Passed \(checks) Reference checks including CLI writes and live catalogue refresh")

var citationExample = ReferenceRecord(key: "Example2026", fields: ["title": "A small observation", "author": "Example, A", "year": "2026"])
try check(ReferenceCitation.text(citationExample, format: .latex) == "\\cite{Example2026}", "LaTeX citation payload")
try check(ReferenceCitation.text(citationExample, format: .markdown) == "[@Example2026]", "Markdown citation payload")
let initialCitation = try ReferenceCitation.appending(citationExample, to: "")
try check(ReferenceCitation.appending(citationExample, to: initialCitation) == initialCitation, "Adding an identical reference is idempotent")
let preservedCitation = "% Keep this comment exactly.\n" + initialCitation
var secondCitation = citationExample; secondCitation.key = "Other2026"
try check(ReferenceCitation.appending(secondCitation, to: preservedCitation).hasPrefix(preservedCitation), "Existing bibliography bytes are preserved")
citationExample.fields["title"] = "Different details"
rejects("Conflicting citation keys") { _ = try ReferenceCitation.appending(citationExample, to: initialCitation) }
rejects("Malformed existing bibliography") { _ = try ReferenceCitation.appending(citationExample, to: "@article{broken") }
let citationPayload = try ReferenceCLI.response(["citation", "--id", external.id.uuidString, "--kind", "markdown"], repository: writeRepo)
try check((citationPayload["citation"] as? String)?.hasPrefix("[@") == true && citationPayload["bibtex"] as? String != nil, "CLI provides portable citation and BibTeX without writing")
print("Passed \(checks) Reference checks including additive citation payloads")

func citationPrefix(_ source: String, caret: Int? = nil) -> ReferenceCitationCompletion.Prefix? { ReferenceCitationCompletion.prefix(source, selection: NSRange(location: caret ?? (source as NSString).length, length: 0)) }
try check(citationPrefix("\\cite{k")?.query == "k", "Partial citation recognised")
try check(citationPrefix("\\citep[see][p. 2]{first,  key")?.query == "key", "Optional arguments and comma-separated keys")
try check(citationPrefix("% \\cite{k") == nil, "Comments do not suggest citations")
try check(citationPrefix("\\\\cite{k") == nil, "Escaped citation command ignored")
try check(citationPrefix("ordinary words") == nil, "Ordinary prose does not load references")
try check(citationPrefix("\\textbf{k") == nil, "Unrelated command ignored")
let middleSource = "\\cite{kaMore,other}", middle = citationPrefix(middleSource, caret: 8)!
let replacedMiddle = (middleSource as NSString).replacingCharacters(in: middle.range, with: "Known" + middle.closing)
try check(replacedMiddle == "\\cite{Known,other}", "Completion preserves remaining citation keys and consumes token suffix")
let closedSource = "\\cite{k}", closed = citationPrefix(closedSource, caret: 7)!
try check((closedSource as NSString).replacingCharacters(in: closed.range, with: "Known" + closed.closing) == "\\cite{Known}", "Existing closing brace is not duplicated")
var localSuggestion = ReferenceRecord(key: "Key2026", fields: ["title": "Local evidence"])
var remoteSuggestion = ReferenceRecord(key: "KeyOther", fields: ["title": "Library evidence"])
let suggestions = ReferenceCitationCompletion.suggestions(query: "Key", project: [localSuggestion], library: [remoteSuggestion, localSuggestion])
try check(suggestions.count == 2 && suggestions[0].project && !suggestions[1].project, "Project references precede library and duplicate keys appear once")
try check(ReferenceCitationCompletion.suggestions(query: "Library evidence", project: [], library: [remoteSuggestion]).count == 1, "Search reference titles")
let abstractSuggestion = ReferenceRecord(key: "AbstractOnly", fields: ["title": "A numerical method", "abstract": "Wall stress and turbulent boundary layers. Énergie is conserved."])
try check(ReferenceCitationCompletion.suggestions(query: "TURBULENT boundary", project: [], library: [abstractSuggestion]).first?.record.citationKey == "AbstractOnly", "Search a library abstract without matching the key")
try check(ReferenceCitationCompletion.suggestions(query: "numerical stress", project: [abstractSuggestion], library: []).first?.project == true, "Query words can span title and abstract")
try check(ReferenceCitationCompletion.suggestions(query: "energie", project: [], library: [abstractSuggestion]).count == 1, "Abstract search folds accents")
let titleSuggestion = ReferenceRecord(key: "TitleOnly", fields: ["title": "Wall turbulence"])
let prefixSuggestion = ReferenceRecord(key: "wall2026", fields: ["title": "Other work"])
try check(ReferenceCitationCompletion.suggestions(query: "wall", project: [], library: [abstractSuggestion, titleSuggestion, prefixSuggestion]).map { $0.record.citationKey } == ["wall2026", "TitleOnly", "AbstractOnly"], "Key prefixes and title metadata rank above abstract-only matches")
let abstractBib = try ReferenceBibTeX.parse("@article{BibAbstract, title={A method}, abstract={Spectral {Galerkin} advection}}")
try check(ReferenceCitationCompletion.suggestions(query: "galerkin", project: abstractBib, library: []).first?.record.citationKey == "BibAbstract", "BibTeX abstract matches through display normalisation")
try check(ReferenceCitationPreferences.destination(["existing.bib"], preferred: nil) == "existing.bib", "Use sole existing bibliography")
try check(ReferenceCitationPreferences.destination(["one.bib", "two.bib"], preferred: nil) == nil, "Ambiguous bibliographies require selection")
try check(ReferenceCitationPreferences.destination(["one.bib", "two.bib"], preferred: "two.bib") == "two.bib", "Remember selected bibliography")
try check(ReferenceCitationPreferences.destination(["one.bib"], preferred: "removed.bib") == "one.bib", "Recover when remembered bibliography disappears")
let preferenceSuite = "remile-citation-tests-" + UUID().uuidString, preferences = UserDefaults(suiteName: preferenceSuite)!
defer { preferences.removePersistentDomain(forName: preferenceSuite) }
ReferenceCitationPreferences.write(.init(library: remoteSuggestion.id, bibliography: "two.bib"), context: "project-one", store: preferences)
try check(ReferenceCitationPreferences.read("project-one", store: preferences).bibliography == "two.bib", "Persist project choice")
try check(ReferenceCitationPreferences.read("project-two", store: preferences).library == nil, "Project choices are isolated")
print("Passed \(checks) Reference checks including citation completion and project preferences")

let suggestedCLI = try ReferenceCLI.response(["suggest", "--library", external.library.uuidString, "--query", external.citationKey], repository: writeRepo)
try check((suggestedCLI["suggestions"] as? [[String: String]])?.contains { $0["id"] == external.id.uuidString } == true, "Agent suggestions use the shared citation matcher")
var agentAbstract = ReferenceRecord(key: "agentAbstract", fields: ["title": "Agent metadata fixture", "abstract": "Anisotropic phonon transport."])
agentAbstract.libraryID = external.library
let agentAbstractRecord = try writeRepo.add([agentAbstract])[0]
let abstractCLI = try ReferenceCLI.response(["suggest", "--library", external.library.uuidString, "--query", "phonon"], repository: writeRepo)
try check((abstractCLI["suggestions"] as? [[String: String]])?.contains { $0["id"] == agentAbstractRecord.id.uuidString && $0["key"] == agentAbstractRecord.citationKey } == true, "Agent CLI suggestions find an abstract-only match and return its key")
rejects("Agent suggestions need an explicit library") { _ = try ReferenceCLI.response(["suggest", "--query", "test"], repository: writeRepo) }
print("Passed \(checks) Reference checks including agent citation suggestions")

let evidenceRoot = output.appendingPathComponent("evidence-catalogue"), evidenceRepository = ReferenceRepository(root: evidenceRoot)
let evidencePDF = output.appendingPathComponent("evidence.pdf")
try (pdfData as Data).write(to: evidencePDF)
let evidenceRecord = try evidenceRepository.importFiles([evidencePDF])[0], evidenceFile = evidenceRecord.attachments[0]
let evidenceBib = try ReferenceExport.bibtex([evidenceRecord])
let resolvedEvidence = try ReferenceEvidence.resolve(key: evidenceRecord.citationKey, sources: ["existing.bib": evidenceBib], library: evidenceRecord.library, repository: evidenceRepository)
try check(resolvedEvidence.id == evidenceRecord.id, "Project citation resolves to exact Reference metadata")
var unrelated = evidenceRecord; unrelated.fields["title"] = "A different paper with the same key"
let unrelatedBib = try ReferenceExport.bibtex([unrelated])
let unresolvedPDF = try ReferenceEvidence.resolve(key: unrelated.citationKey, sources: ["existing.bib": unrelatedBib], library: evidenceRecord.library, repository: evidenceRepository)
try check(unresolvedPDF.attachments.isEmpty, "A key collision never borrows a different paper's PDF")
rejects("Conflicting project bibliographies") { _ = try ReferenceEvidence.resolve(key: evidenceRecord.citationKey, sources: ["one.bib": evidenceBib, "two.bib": unrelatedBib], library: nil, repository: evidenceRepository) }
try check(ReferenceEvidence.key(in: "\\cite{known,other}", selection: NSRange(location: 8, length: 0)) == "known", "Inspect citation key under caret")
try check(ReferenceEvidence.key(in: "% \\cite{known}", selection: NSRange(location: 10, length: 0)) == nil, "Inspect ignores commented citations")
let evidencePayload = try ReferenceCLI.response(["evidence", "--id", evidenceRecord.id.uuidString, "--attachment", evidenceFile.id.uuidString, "--page", "1"], repository: evidenceRepository)
try check((evidencePayload["text"] as? String)?.isEmpty == false && evidencePayload["sha256"] as? String == evidenceFile.sha256, "CLI returns verified PDF text with attachment provenance")
rejects("Unknown attachment cannot be read") { _ = try ReferenceEvidence.attachment(recordID: evidenceRecord.id, attachmentID: UUID(), repository: evidenceRepository) }
rejects("Invalid PDF page") { _ = try ReferenceEvidence.page(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, page: 999, repository: evidenceRepository) }
try Data("changed".utf8).write(to: evidenceRepository.attachmentURL(evidenceFile))
rejects("Changed PDF cannot be read as verified evidence") { _ = try ReferenceEvidence.attachment(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, repository: evidenceRepository) }
print("Passed \(checks) Reference checks including verified source access")

let preparedProject = ReferenceCitationIndex([localSuggestion]), preparedLibrary = ReferenceCitationIndex([remoteSuggestion, localSuggestion])
let preparedMatches = ReferenceCitationCompletion.suggestions(query: "Key", project: preparedProject, library: preparedLibrary)
try check(preparedMatches.map { $0.record.citationKey } == suggestions.map { $0.record.citationKey }, "Prepared matching preserves project priority and duplicate suppression")
try check(ReferenceCitationCompletion.suggestions(query: "", project: preparedProject, library: preparedLibrary, limit: 0).isEmpty, "Zero result budget does no matching")
let accented = ReferenceRecord(key: "Accent2026", fields: ["title": "Écoulement", "author": "Åström, A"])
try check(ReferenceCitationCompletion.suggestions(query: "ecoulement astrom", project: ReferenceCitationIndex(), library: ReferenceCitationIndex([accented])).count == 1, "Prepared citation search handles accents consistently")
print("Passed \(checks) Reference checks including prepared matching")

// Saved evidence always comes from verified PDF text, not agent-provided prose.
try (pdfData as Data).write(to: evidenceRepository.attachmentURL(evidenceFile))
let passagePage = try ReferenceEvidence.page(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, page: 1, repository: evidenceRepository)
let passageText = passagePage["text"] as! String
let passageRange = NSRange(location: 0, length: min(12, (passageText as NSString).length))
let savedPassage = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, expectedSHA256: evidenceFile.sha256, page: 1, range: passageRange, repository: evidenceRepository)
try check(savedPassage.text == (passageText as NSString).substring(with: passageRange), "Passage text is extracted from the verified PDF range")
let repeatedPassage = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, expectedSHA256: evidenceFile.sha256, page: 1, range: passageRange, repository: evidenceRepository)
try check(repeatedPassage.id == savedPassage.id, "Saving the same evidence does not create duplicates")
try check(try ReferencePassages.list(recordID: evidenceRecord.id, repository: ReferenceRepository(root: evidenceRoot)) == [savedPassage], "Passage survives a new repository session")
let passageCLI = try ReferenceCLI.response(["passages", "--id", evidenceRecord.id.uuidString], repository: evidenceRepository)
try check((passageCLI["passages"] as? [[String: Any]])?.first?["text"] as? String == savedPassage.text, "CLI reads native saved evidence")
let saveCLI = try ReferenceCLI.response(["save-passage", "--id", evidenceRecord.id.uuidString, "--attachment", evidenceFile.id.uuidString, "--expected-sha256", evidenceFile.sha256, "--page", "1", "--start", "0", "--length", String(passageRange.length)], repository: evidenceRepository)
try check((saveCLI["passage"] as? [String: Any])?["id"] as? String == savedPassage.id.uuidString, "CLI uses the same verified deduplicating writer")
rejects("Evidence save rejects outdated PDF hash") { _ = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, expectedSHA256: String(repeating: "0", count: 64), page: 1, range: passageRange, repository: evidenceRepository) }
rejects("Evidence save rejects overflowing range") { _ = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, expectedSHA256: evidenceFile.sha256, page: 1, range: NSRange(location: Int.max, length: 1), repository: evidenceRepository) }
rejects("Evidence save rejects empty selection") { _ = try ReferencePassages.save(recordID: evidenceRecord.id, attachmentID: evidenceFile.id, expectedSHA256: evidenceFile.sha256, page: 1, range: NSRange(location: 0, length: 0), repository: evidenceRepository) }
rejects("Evidence CLI requires the PDF hash") { _ = try ReferenceCLI.response(["save-passage", "--id", evidenceRecord.id.uuidString, "--attachment", evidenceFile.id.uuidString, "--page", "1", "--start", "0", "--length", "2"], repository: evidenceRepository) }
try evidenceRepository.trash(evidenceRecord.id)
rejects("Evidence in Trash is not exposed") { _ = try ReferencePassages.list(recordID: evidenceRecord.id, repository: evidenceRepository) }
try evidenceRepository.trash(evidenceRecord.id, restore: true)
try check(try ReferencePassages.list(recordID: evidenceRecord.id, repository: evidenceRepository).count == 1, "Restoring a reference restores access to its evidence")
try evidenceRepository.trash(evidenceRecord.id)
try evidenceRepository.emptyTrash()
try check(!FileManager.default.fileExists(atPath: evidenceRoot.appendingPathComponent("Passages/" + evidenceRecord.id.uuidString + ".json").path), "Permanent reference removal also removes stored passages")
let undoRoot = output.appendingPathComponent("undo")
let undoHistory = ReferenceRepository.History()
let undoRepository = ReferenceRepository(root: undoRoot, history: undoHistory)
let undoLibrary = try undoRepository.addLibrary("Writing")
let undoRecord = try undoRepository.add([ReferenceRecord(fields: ["title": "Original"])], libraryID: undoLibrary.id)[0]
var undoEdited = undoRecord; undoEdited.fields["title"] = "Edited"
let undoSaved = try undoRepository.update(undoEdited, expected: undoEdited.revision)
try undoRepository.undo()
let undone = try undoRepository.records()[0]
try check(undone.title == "Original" && undone.revision != undoRecord.revision, "Undo restores metadata with a fresh revision")
rejects("Undo never revives a stale CLI revision") { _ = try undoRepository.update(undoEdited, expected: undoRecord.revision) }
try undoRepository.undo(redo: true)
try check(try undoRepository.records()[0].title == "Edited", "Redo reapplies metadata")
try undoRepository.undo()
try undoRepository.undo()
try check(try undoRepository.records().isEmpty, "Consecutive undo removes an added record")
try undoRepository.undo()
try check(try undoRepository.libraries() == [.primary], "Library creation can be undone")
try undoRepository.undo(redo: true)
try undoRepository.undo(redo: true)
try check(try undoRepository.records()[0].title == "Original", "Consecutive redo restores library and record")
var branchEdit = try undoRepository.records()[0]; branchEdit.fields["title"] = "New branch"
_ = try undoRepository.update(branchEdit, expected: branchEdit.revision)
try check(!undoHistory.canRedo, "A new edit discards redo history")
let externalRepository = ReferenceRepository(root: undoRoot)
var externalEdit = try externalRepository.records()[0]; externalEdit.fields["title"] = "CLI edit"
_ = try externalRepository.update(externalEdit, expected: externalEdit.revision)
rejects("External edits are not overwritten") { try undoRepository.undo() }
try check(try !undoHistory.canUndo && !undoHistory.canRedo && externalRepository.records()[0].title == "CLI edit", "External change clears session history")
let undoAttachment = try undoRepository.importFiles([evidencePDF], attachingTo: externalEdit.id, expected: try undoRepository.records()[0].revision)[0]
try undoRepository.removeAttachments(Set(undoAttachment.attachments.map(\.id)), from: undoAttachment.id, expected: undoAttachment.revision)
try undoRepository.undo()
try check(try undoRepository.records()[0].attachments.count == 1, "Undo restores an unlinked attachment")
try undoRepository.undo()
try check(try undoRepository.records()[0].attachments.isEmpty, "Undo reverses attachment import")
try undoRepository.undo(redo: true)
try check(try undoRepository.records()[0].attachments.count == 1, "Redo reuses existing PDF bytes")
let refreshedAttachment = try undoRepository.records()[0].attachments[0]
try undoRepository.refreshAttachment(refreshedAttachment.id)
try check(undoHistory.canUndo, "An unchanged PDF refresh preserves undo history")
try Data("Changed synthetic PDF bytes".utf8).write(to: undoRepository.attachmentURL(refreshedAttachment))
try undoRepository.refreshAttachment(refreshedAttachment.id)
try check(!undoHistory.canUndo && !undoHistory.canRedo, "Changed PDF bytes cannot be undone as metadata")
try undoRepository.trash(externalEdit.id)
try undoRepository.emptyTrash()
try check(!undoHistory.canUndo && !undoHistory.canRedo, "Empty Trash ends undo history")
try check(try undoRepository.records().isEmpty, "Permanently deleted records stay deleted")
let boundedHistory = ReferenceRepository.History()
let boundedRepository = ReferenceRepository(root: output.appendingPathComponent("bounded-undo"), history: boundedHistory)
for index in 0..<32 { _ = try boundedRepository.add([ReferenceRecord(fields: ["title": "Item \(index)"])]) }
for _ in 0..<30 { try boundedRepository.undo() }
try check(try !boundedHistory.canUndo && boundedRepository.records().count == 2, "Undo retains at most thirty changes")
let collectRepository = ReferenceRepository(root: output.appendingPathComponent("collect"))
let collected = try ReferenceCollect.save(pdfURL, library: ReferenceLibrary.primaryID, repository: collectRepository)
let collectedAgain = try ReferenceCollect.save(pdfURL, library: ReferenceLibrary.primaryID, repository: collectRepository)
try check(collected.id == collectedAgain.id && (try collectRepository.records()).count == 1, "Collect reuses an existing reference")
try check(collected.attachments == collectedAgain.attachments, "Collect reuses managed PDF bytes")
try check(try Data(contentsOf: pdfURL) == pdfBytes, "Collect preserves source PDF")
let collectedCLI = try ReferenceCLI.response(["collect", "--library", ReferenceLibrary.primaryID.uuidString, "--source-file", pdfURL.path], repository: collectRepository)
try check(collectedCLI["id"] as? String == collected.id.uuidString, "CLI collect uses the same operation")
_ = try collectRepository.importFiles([pdfURL])
let countBeforeAmbiguous = try collectRepository.records().count
rejects("Collect never guesses between duplicate references") { _ = try ReferenceCollect.save(pdfURL, library: ReferenceLibrary.primaryID, repository: collectRepository) }
try check(try collectRepository.records().count == countBeforeAmbiguous, "Ambiguous collect has no catalogue mutation")
rejects("Collect accepts PDFs only") { _ = try ReferenceCollect.save(bad, library: ReferenceLibrary.primaryID, repository: collectRepository) }
let collectCollection = try collectRepository.addLibrary("Chosen collection", parentID: ReferenceLibrary.primaryID)
let inCollection = try ReferenceCollect.save(pdfURL, library: collectCollection.id, repository: collectRepository)
try check(inCollection.collectionID == collectCollection.id, "Collect honours the chosen collection")
try check(inCollection.attachments == collected.attachments, "A new collection shares existing managed PDF bytes")
let inCollectionAgain = try ReferenceCollect.save(pdfURL, library: collectCollection.id, repository: collectRepository)
try check(inCollection.id == inCollectionAgain.id, "Repeated collect stays idempotent within a collection")
print("Passed \(checks) Reference checks including durable PDF passages")

let attachDraft = try collectRepository.add([ReferenceRecord(fields: ["title": "A retained original title", "doi": "10.1234/fixture"])])[0]
let attachedFound = try collectRepository.addFetched(attachDraft, pdf: pdfBytes, libraryID: attachDraft.library, attachingTo: attachDraft.id, expected: attachDraft.revision)
try check(attachedFound.fields == attachDraft.fields && attachedFound.key == attachDraft.key && attachedFound.id == attachDraft.id, "Found PDF preserves the selected entry identity and fields")
try check(attachedFound.attachments.count == 1 && attachedFound.revision != attachDraft.revision, "Found PDF attaches with a new revision")
rejects("Stale found-PDF target") { _ = try collectRepository.addFetched(attachDraft, pdf: pdfBytes, libraryID: attachDraft.library, attachingTo: attachDraft.id, expected: attachDraft.revision) }
let attachedAgain = try collectRepository.addFetched(attachedFound, pdf: pdfBytes, libraryID: attachedFound.library, attachingTo: attachedFound.id, expected: attachedFound.revision)
try check(attachedAgain.attachments.count == 1, "Repeated found PDF does not duplicate bytes")
try check(ReferencePaperLookup.matches(attachDraft, fields: ["doi": "https://doi.org/10.1234/FIXTURE"]), "PDF DOI matching normalises links and case")
try check(!ReferencePaperLookup.matches(attachDraft, fields: ["doi": "10.1234/other", "title": attachDraft.title]), "Conflicting DOI prevents a title-only PDF match")
try check(ReferencePaperLookup.matches(attachDraft, fields: ["title": "A retained ORIGINAL title"]), "PDF title match ignores case")
try check(!ReferencePaperLookup.matches(ReferenceRecord(fields: ["title": "Intro"]), fields: ["title": "Intro"]), "Short ambiguous titles do not auto-match PDFs")
let moveSource = output.appendingPathComponent("storage-source")
let moveRepo = ReferenceRepository(root: moveSource)
let moveRecord = try moveRepo.addFetched(ReferenceRecord(fields: ["title": "A storage migration fixture"]), pdf: pdfBytes, libraryID: ReferenceLibrary.primaryID)
let storageParent = output.appendingPathComponent("storage-parent"); try FileManager.default.createDirectory(at: storageParent, withIntermediateDirectories: true)
let storeName = "remile.storage-checks." + UUID().uuidString
let defaults = UserDefaults(suiteName: storeName)!
defer { defaults.removePersistentDomain(forName: storeName) }
let moved = try moveRepo.withLibraryLock { try StoragePaths.relocate(from: moveSource, into: storageParent, defaults: defaults) }
let movedRepo = ReferenceRepository(root: moved)
try check(try movedRepo.records() == moveRepo.records(), "Migration preserves catalogue identities and revisions")
try check(try Data(contentsOf: movedRepo.attachmentURL(moveRecord.attachments[0])) == pdfBytes, "Migration verifies and retains PDF bytes")
try check(FileManager.default.fileExists(atPath: moveRepo.attachmentURL(moveRecord.attachments[0]).path), "Migration retains the previous files for recovery")
try check(defaults.string(forKey: StoragePaths.referencePreference) == moved.path, "Verified migration activates the destination")
defaults.set(moveSource.path, forKey: StoragePaths.referencePreference)
try check(StoragePaths.reference(defaults: defaults) == moved, "Old processes follow the relocation marker")
rejects("Existing migration destination") { _ = try StoragePaths.relocate(from: moved, into: storageParent, defaults: defaults) }
rejects("Nested storage folder") { _ = try StoragePaths.relocate(from: moved, into: moved, defaults: defaults) }
let unsafeParent = output.appendingPathComponent("unsafe-parent"); try FileManager.default.createDirectory(at: unsafeParent, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: moved.appendingPathComponent("unsafe-link"), withDestinationURL: pdfURL)
rejects("Symlink migration") { _ = try StoragePaths.relocate(from: moved, into: unsafeParent, defaults: defaults) }
try check(!FileManager.default.fileExists(atPath: unsafeParent.appendingPathComponent("remile-reference").path), "Failed migration never publishes a partial library")
try check(defaults.string(forKey: StoragePaths.referencePreference) == moveSource.path, "Failed migration retains the previous setting")
rejects("Missing external storage") { try StoragePaths.requireAvailable(output.appendingPathComponent("absent-volume")) }
let storageCLI = try ReferenceCLI.response(["storage"], repository: movedRepo)
try check(storageCLI["referenceDirectory"] as? String == moved.path, "CLI reports the same library directory")
print("Passed \(checks) Reference checks including storage migration and found PDFs")

let localMatch = ReferenceRecord(fields: ["title": "A careful study of reference metadata", "doi": "10.1234/pdf-evidence"])
let localFixture = output.appendingPathComponent("local-lookup.pdf"); try (pdfData as Data).write(to: localFixture)
try check(try ReferencePaperLookup.localPDFs(for: localMatch, candidates: [localFixture, localFixture]).count == 1, "Local lookup verifies first-page DOI and deduplicates files")
try check(try ReferencePaperLookup.localPDFs(for: attachDraft, candidates: [localFixture]).isEmpty, "Unrelated open PDF is not proposed")
print("Passed \(checks) Reference checks including local PDF lookup")

let blockedParent = output.appendingPathComponent("blocked-parent"); try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
let blockedSource = output.appendingPathComponent("blocked-source"); try FileManager.default.createDirectory(at: blockedSource, withIntermediateDirectories: true)
try Data("retained".utf8).write(to: blockedSource.appendingPathComponent("example"))
rejects("Cancelled final storage switch") { _ = try StoragePaths.relocate(from: blockedSource, into: blockedParent, defaults: defaults, commit: { _ in throw ReferenceFailure("An open document prevents relocation") }) }
try check(!FileManager.default.fileExists(atPath: blockedParent.appendingPathComponent("remile-reference").path), "Rejected final switch retains source and removes staging files")
try check(try Data(contentsOf: blockedSource.appendingPathComponent("example")) == Data("retained".utf8), "Rejected final switch preserves source bytes")
print("Passed \(checks) Reference checks including rejected storage publication")

try check(attachedAgain.revision == attachedFound.revision, "An already attached PDF leaves the record revision unchanged")
let repairRepo = ReferenceRepository(root: output.appendingPathComponent("repair-found-pdf"))
let repairDraft = try repairRepo.addFetched(ReferenceRecord(fields: ["title": "Recover an unavailable attachment"]), pdf: pdfBytes, libraryID: ReferenceLibrary.primaryID)
try FileManager.default.removeItem(at: repairRepo.attachmentURL(repairDraft.attachments[0]))
let repairedPDF = try repairRepo.addFetched(repairDraft, pdf: pdfBytes, libraryID: repairDraft.library, attachingTo: repairDraft.id, expected: repairDraft.revision)
try check(repairedPDF.attachments.count == 1 && repairedPDF.attachments[0].id != repairDraft.attachments[0].id, "Found PDF repairs a missing stored attachment")
try check(try Data(contentsOf: repairRepo.attachmentURL(repairedPDF.attachments[0])) == pdfBytes, "Repaired attachment points to verified stored bytes")
print("Passed \(checks) Reference checks including missing attachment recovery")

let sortOld = ReferenceRecord(fields: ["title": "Beta 2", "author": "Zulu, Alice", "year": "9", "journal": "Zebra"])
let sortNew = ReferenceRecord(fields: ["title": "Alpha 10", "author": "Adams, Eve", "year": "10", "journal": "Atlas"])
let sortMissing = ReferenceRecord(fields: ["title": "Gamma", "year": ""])
let sortUnknown = ReferenceRecord(fields: ["title": "Delta", "year": "n.d."])
let sortData = [sortOld, sortNew, sortMissing, sortUnknown]
try check(ReferenceSort().sorted(sortData).map(\.id) == [sortNew, sortOld, sortUnknown, sortMissing].map(\.id), "Titles sort alphabetically")
try check(ReferenceSort(column: .year).sorted(sortData).map(\.id) == [sortOld, sortNew, sortUnknown, sortMissing].map(\.id), "Years sort numerically with unknown values last")
try check(ReferenceSort(column: .year, ascending: false).sorted(sortData).prefix(2).map(\.id) == [sortNew.id, sortOld.id], "Descending years keep populated numeric years first")
try check(ReferenceSort(column: .author).sorted(sortData).first?.id == sortNew.id, "Authors sort by full names")
try check(ReferenceSort(column: .publication, ascending: false).sorted(sortData).first?.id == sortOld.id, "Publication sorting uses displayed publication fields")
var sortToggle = ReferenceSort(); sortToggle.select(.year)
try check(sortToggle.column == .year && sortToggle.ascending, "New column starts ascending")
sortToggle.select(.year); try check(!sortToggle.ascending, "Repeated heading click reverses order")
sortToggle.select(.type); try check(sortToggle.ascending, "Switching headings resets to ascending")
let sortingRepo = ReferenceRepository(root: output.appendingPathComponent("sorting")); let sortedStored = try sortingRepo.add(sortData)
let sortedCLI = try ReferenceCLI.response(["list", "--sort", "year", "--order", "desc", "--limit", "2"], repository: sortingRepo)
let cliSortIDs = (sortedCLI["references"] as! [[String: Any]]).map { $0["id"] as! String }
try check(cliSortIDs == [sortedStored[1].id.uuidString, sortedStored[0].id.uuidString], "CLI sorts before pagination using the native comparator")
rejects("Unknown sort column") { _ = try ReferenceCLI.response(["list", "--sort", "unknown"], repository: sortingRepo) }
rejects("Unknown sort direction") { _ = try ReferenceCLI.response(["list", "--order", "reverse"], repository: sortingRepo) }
let sortModel = MainActor.assumeIsolated { ReferenceModel(repository: sortingRepo) }
MainActor.assumeIsolated { sortModel.load() }
let sortDeadline = Date().addingTimeInterval(5)
while MainActor.assumeIsolated({ sortModel.busy }) && Date() < sortDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
try check(MainActor.assumeIsolated { sortModel.items.count == 4 }, "Native sort model loads the synthetic rows")
MainActor.assumeIsolated { sortModel.selected = sortedStored[0].id; sortModel.selectedIDs = [sortedStored[0].id]; sortModel.sort(by: .year); sortModel.sort(by: .year) }
try check(MainActor.assumeIsolated { sortModel.items.first?.id == sortedStored[1].id && sortModel.selected == sortedStored[0].id }, "Native heading reorder preserves selection and invalidates cached order")
MainActor.assumeIsolated { sortModel.query = "Alpha" }
try check(MainActor.assumeIsolated { sortModel.items.count == 1 }, "Changing the query invalidates cached rows")
MainActor.assumeIsolated { sortModel.query = ""; sortModel.showingTrash = true }
try check(MainActor.assumeIsolated { sortModel.items.isEmpty }, "Trash visibility invalidates cached rows")
let columnStoreName = "remile.column-checks." + UUID().uuidString; let columnStore = UserDefaults(suiteName: columnStoreName)!
defer { columnStore.removePersistentDomain(forName: columnStoreName) }
columnStore.set("title,author,publication,year", forKey: ReferenceColumn.preference); ReferenceColumn.applyDefaults(columnStore)
try check(ReferenceColumn.visible(columnStore.string(forKey: ReferenceColumn.preference)!).contains(.type), "Type is added to the old default column layout")
columnStore.set("title,year", forKey: ReferenceColumn.preference); ReferenceColumn.applyDefaults(columnStore)
try check(columnStore.string(forKey: ReferenceColumn.preference) == "title,year", "Hiding Type after migration stays respected")
print("Passed \(checks) Reference checks including shared column sorting")

try check(ReferencePDFMetadata.placeholderTitle("arXiv:1706.03762v7 [cs.CL] 2 Aug 2023"), "arXiv margin stamps are not titles")
try check(ReferencePDFMetadata.arxivID(in: "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023") == "1706.03762v7", "Local PDF extraction recognises versioned arXiv identifiers")
try check(ReferencePDFMetadata.arxivID(in: "arXiv:1706.03762 https://arxiv.org/abs/1706.03762v7") != nil, "Versioned and unversioned forms identify the same paper")
try check(ReferencePDFMetadata.arxivID(in: "arXiv:1706.03762 arXiv:2301.00001") == nil, "Conflicting archive identifiers stay ambiguous")
try check(ReferenceColumnWidths.decode("{\"title\":99999,\"year\":1}")["title"] == 1200, "Column widths clamp unusually large persisted values")
try check(ReferenceColumnWidths.decode("{\"year\":1}")["year"] == 44, "Small columns retain a usable minimum")
try check(ReferenceColumnWidths.decode("not JSON").isEmpty, "Invalid stored widths fall back to defaults")
try check(ReferenceColumnWidths.decode(ReferenceColumnWidths.encode(["title": 420, "publication": 130])) == ["title": 420, "publication": 130], "Manual column widths round trip")
print("Passed \(checks) Reference checks including metadata and column resizing")

let arxivBytes = NSMutableData(); var arxivBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let arxivContext = CGContext(consumer: CGDataConsumer(data: arxivBytes)!, mediaBox: &arxivBox, nil)!
arxivContext.beginPDFPage(nil)
for (line, size, y) in [("arXiv:1706.03762v7 [cs.CL] 2 Aug 2023", 14.0, 760.0), ("Attention Is All You Need", 22.0, 710.0), ("Abstract", 12.0, 600.0)] {
 arxivContext.textPosition = CGPoint(x: 40, y: y)
 CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: size)])), arxivContext)
}
arxivContext.endPDFPage(); arxivContext.closePDF()
let arxivPDF = PDFDocument(data: arxivBytes as Data)!
arxivPDF.documentAttributes = [PDFDocumentAttribute.titleAttribute: "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023"]
let arxivFields = ReferencePDFMetadata.fields(arxivPDF, fallback: "fixture")
try check(arxivFields["title"] == "Attention Is All You Need" && arxivFields["eprint"] == "1706.03762v7", "Local parser distinguishes a margin stamp from the actual paper title")
let arxivRepo = ReferenceRepository(root: output.appendingPathComponent("arxiv-cleanup"))
let badArxiv = try arxivRepo.addFetched(ReferenceRecord(fields: ["title": "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023"]), pdf: arxivBytes as Data, libraryID: ReferenceLibrary.primaryID)
let localChanges = try ReferenceCleanup.proposals([badArxiv], repository: arxivRepo)
try check(localChanges.count == 1 && localChanges[0].after.title == "Attention Is All You Need" && localChanges[0].after.type == "misc", "Existing bad arXiv imports receive a local reversible metadata repair")
try arxivRepo.applyCleanup(localChanges)
let fixedArxiv = try arxivRepo.records()[0]
try check(fixedArxiv.key == badArxiv.key && fixedArxiv.attachments == badArxiv.attachments && fixedArxiv.type == "misc", "Applying local metadata repairs preserves citation keys and attachments")
print("Passed \(checks) Reference checks including arXiv margin-stamp recovery")

// A second Mac selects its own synced path. Reading never creates a catalogue or lock.
let secondMac = output.appendingPathComponent("second-mac-synced-library")
try FileManager.default.copyItem(at: moved, to: secondMac)
try StoragePaths.connect(to: secondMac, defaults: defaults)
try check(StoragePaths.reference(defaults: defaults).path == secondMac.path && StoragePaths.isReadOnly(secondMac, defaults: defaults), "Existing synced library connects read only using this Mac's path")
let sharedRead = ReferenceRepository(root: secondMac, readOnly: true)
let sharedRecords = try sharedRead.records()
let movedRecords = try movedRepo.records()
try check(sharedRecords.map(\.id) == movedRecords.map(\.id), "Second Mac retains stable reference identities")
try check(try Data(contentsOf: sharedRead.attachmentURL(sharedRecords[0].attachments[0])) == pdfBytes, "Relative PDF attachments survive a different Mac path")
let beforeShared = try Data(contentsOf: secondMac.appendingPathComponent("library.json"))
rejects("Shared read-only catalogue rejects edits") { _ = try sharedRead.addLibrary("Must not appear") }
rejects("CLI writes share the read-only boundary") { _ = try ReferenceCLI.response(["trash", "--id", sharedRecords[0].id.uuidString, "--expected-revision", sharedRecords[0].revision.uuidString], repository: sharedRead) }
try check(try Data(contentsOf: secondMac.appendingPathComponent("library.json")) == beforeShared, "Rejected edits preserve cloud catalogue bytes")
let noSync = output.appendingPathComponent("not-downloaded-yet")
try FileManager.default.createDirectory(at: noSync, withIntermediateDirectories: true)
rejects("Unfinished sync never becomes an empty replacement") { try StoragePaths.connect(to: noSync, defaults: defaults) }
try check(StoragePaths.reference(defaults: defaults).path == secondMac.path, "Failed connection preserves active library")
let malformedSync = output.appendingPathComponent("malformed-sync")
try FileManager.default.createDirectory(at: malformedSync, withIntermediateDirectories: true)
try Data("not a catalogue".utf8).write(to: malformedSync.appendingPathComponent("library.json"))
rejects("Invalid synced catalogue does not change storage") { try StoragePaths.connect(to: malformedSync, defaults: defaults) }
rejects("Cancelled library switch preserves preferences") { try StoragePaths.connect(to: moved, defaults: defaults, commit: { _ in throw ReferenceFailure("Cancelled") }) }
try check(StoragePaths.reference(defaults: defaults).path == secondMac.path, "Cancelled switch leaves the old connection intact")
settingsStore.set(secondMac.path, forKey: StoragePaths.referencePreference)
settingsStore.set(secondMac.path, forKey: StoragePaths.readOnlyPreference)
let preset = PortableSettings.snapshot(settingsStore)
try check(preset.preferences[StoragePaths.referencePreference] == nil && preset.preferences[StoragePaths.readOnlyPreference] == nil, "Presets exclude machine-specific storage and access mode")
let importedPreset = "remile.preset-destination." + UUID().uuidString
let importedStore = UserDefaults(suiteName: importedPreset)!
defer { importedStore.removePersistentDomain(forName: importedPreset) }
try PortableSettings.apply(preset, to: importedStore)
ReferenceColumn.applyDefaults(importedStore)
try check(importedStore.string(forKey: ReferenceColumn.preference) == "title,publisher,year", "A preset's exact columns survive fresh-install migration")
try check(importedStore.string(forKey: StoragePaths.referencePreference) == nil, "Loading a preset does not redirect the receiving Mac's library")
print("Passed \(checks) Reference checks including shared-folder reading and presets")

rejects("Read-only PDF save cannot alter the synced original") { try StorageFileAccess.requireWritable(sharedRead.attachmentURL(sharedRecords[0].attachments[0]), defaults: defaults) }
try StorageFileAccess.requireWritable(output.appendingPathComponent("personal-copy.pdf"), defaults: defaults)
try check(true, "A read-only library still allows copies outside its folder")
print("Passed \(checks) Reference checks including read-only PDF protection")
let emptyMove = output.appendingPathComponent("empty-move-source")
let emptyParent = output.appendingPathComponent("empty-move-parent")
try FileManager.default.createDirectory(at: emptyMove, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: emptyParent, withIntermediateDirectories: true)
let emptyDestination = try StoragePaths.relocate(from: emptyMove, into: emptyParent, defaults: defaults)
try StoragePaths.connect(to: emptyDestination, defaults: defaults)
try check(try ReferenceRepository(root: emptyDestination, readOnly: true).records().isEmpty, "A new empty library remains openable after moving")
let partialMove = output.appendingPathComponent("partial-move-source")
let partialParent = output.appendingPathComponent("partial-move-parent")
try FileManager.default.createDirectory(at: partialMove, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: partialParent, withIntermediateDirectories: true)
try pdfBytes.write(to: partialMove.appendingPathComponent("unsynced.pdf"))
rejects("Missing catalogue with existing files cannot be moved as an empty library") { _ = try StoragePaths.relocate(from: partialMove, into: partialParent, defaults: defaults) }
print("Passed \(checks) Reference checks including empty and partial cloud folders")


// Retrieval must not turn topic overlap into a scientific support verdict.
let trendPaper = ReferenceRecord(key: "TrendML", fields: ["title": "Machine learning in turbulent combustion", "abstract": "Machine learning is increasingly used in turbulent combustion modelling. This review surveys neural networks."])
let chemistryPaper = ReferenceRecord(key: "Hydrogen", fields: ["title": "Ammonia and hydrogen ignition", "abstract": "Ammonia reactivity and hydrogen ignition delays depend on pressure and temperature."])
let toolPaper = ReferenceRecord(key: "Tool", fields: ["title": "OpenFOAM chemical solver with GRI-Mech 3.0", "abstract": "Implementation of a chemical mechanism in OpenFOAM."])
let otherVersion = ReferenceRecord(key: "EarlierTool", fields: ["title": "OpenFOAM chemical solver with GRI-Mech 2.0"])
let unrelatedPaper = ReferenceRecord(key: "Astro", fields: ["title": "Stellar mass in distant galaxies", "abstract": "An astronomical observation of galaxies."])
let relevanceIndex = ReferenceCitationIndex([unrelatedPaper, chemistryPaper, trendPaper, toolPaper, otherVersion])
let trendContext = "Recent research increasingly uses ML in turbulent combustion."
let trendRank = ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: relevanceIndex, context: trendContext)
try check(trendRank.first?.record.key == "TrendML", "ML expansion and context rank relevant research above alphabetical keys")
try check(trendRank.first?.relevance?.label == "Topic match", "Substantial title and abstract overlap is labelled as topic match")
try check(trendRank.first?.relevance?.intents.contains(.background) == true, "Trend cues retain a background purpose")
try check(trendRank.first?.relevance?.intents.contains(.method) == true, "One citation context may have overlapping purposes")
try check(trendRank.first?.relevance?.note.contains("version") == true, "Method purpose asks for source and version checks")
try check(trendRank.first(where: { $0.record.key == "Astro" })?.relevance?.label == "No clear match", "Unrelated papers stay available without a false positive")
try check(trendRank.first?.relevance?.excerpt.contains("combustion") == true, "Displayed excerpt comes from the stored abstract")
let factContext = "Ammonia has weak reactivity and hydrogen ignition depends on pressure and temperature."
let factRank = ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: relevanceIndex, context: factContext)
try check(factRank.first?.record.key == "Hydrogen", "A physical context prefers chemistry over broad machine-learning research")
try check(factRank.first?.relevance?.intents.contains(.foundation) == true && factRank.first?.relevance?.note.contains("conditions") == true, "Physical claims require original source conditions")
let methodRank = ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: relevanceIndex, context: "We implemented the chemical solver using OpenFOAM and GRI-Mech 3.0.")
try check(methodRank.first?.record.key == "Tool", "Exact tool version tokens help distinguish nearby methods")
let compareContext = ReferenceRelevance.Context("The measured flame speed agrees with the benchmark within 3% error.")
try check(compareContext.intents.contains(.comparison), "Benchmarks and error comparisons are recognised")
try check(ReferenceRelevance.assess(relevanceIndex.entries[0].document, context: compareContext)?.note.contains("units") == true, "Comparisons ask for values, units and conditions rather than verifying a number")
let explicitKey = ReferenceCitationCompletion.suggestions(query: "Astro", project: ReferenceCitationIndex(), library: relevanceIndex, context: factContext)
try check(explicitKey.first?.record.key == "Astro" && explicitKey.first?.relevance?.label == "No clear match", "Context ranking never hides an explicitly typed key")
try check(ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: relevanceIndex).allSatisfy { $0.relevance == nil }, "Absent context adds no invented assessment")
try check(ReferenceRelevance.Context("We report our study.").terms.count < 2, "Generic prose cannot create a topical recommendation")
let titleOnlyAssessment = ReferenceRelevance.assess(ReferenceRelevance.Document(title: "Hydrogen ammonia ignition", abstract: ""), context: ReferenceRelevance.Context(factContext))
try check(titleOnlyAssessment?.basis == "Title only", "Title-only evidence is disclosed even when related")
let wrappedCite = "Unrelated astronomical background.\n\nAmmonia ignition depends on pressure\nand temperature \\cite{Old, "
let currentSentence = ReferenceRelevance.sentence(wrappedCite, before: wrappedCite.utf16.count)
try check(currentSentence.contains("Ammonia") && !currentSentence.contains("astronomical") && !currentSentence.contains("Old"), "Citation context crosses wrapped lines but excludes earlier paragraphs and citation keys")
try check(ReferenceRelevance.sentence("x", before: Int.max).isEmpty, "Invalid caret bounds return no context")
let cappedDocument = ReferenceRelevance.Document(title: "Bounded input", abstract: String(repeating: "a", count: 30_000))
try check(cappedDocument.abstract.count == 12_000, "Abstract indexing has a fixed text budget")
var completeMetadata = chemistryPaper; completeMetadata.fields["doi"] = "10.1234/example"; completeMetadata.fields["author"] = "Example, A"; completeMetadata.fields["year"] = "2025"
try check(ReferenceRecognition.eligible(completeMetadata), "Manual lookup remains available when authors and year exist and no PDF is attached")
try check(!ReferenceRecognition.automaticEligible(completeMetadata), "Manual availability does not trigger automatic import lookups")
var titleLookup = chemistryPaper; titleLookup.fields.removeValue(forKey: "abstract"); titleLookup.fields["title"] = "Ammonia and hydrogen ignition properties"
try check(ReferenceRecognition.eligible(titleLookup), "Manual lookup can use a full title without a DOI")
var fetchedTitle = titleLookup; fetchedTitle.fields["abstract"] = "New abstract"; fetchedTitle.fields["doi"] = "10.1234/filled"
let titleMerged = try ReferenceRecognition.merged(titleLookup, with: fetchedTitle)
try check(titleMerged.fields["abstract"] == "New abstract" && titleMerged.id == titleLookup.id, "Exact title enrichment fills missing fields and preserves reference identity")
var wrongTitle = fetchedTitle; wrongTitle.fields["title"] = "Different study"
rejects("Title enrichment refuses an unrelated response") { _ = try ReferenceRecognition.merged(titleLookup, with: wrongTitle) }
var discarded = completeMetadata; discarded.trashed = Date()
try check(!ReferenceRecognition.eligible(discarded), "Trash does not permit metadata lookup")
try EditorCLIArguments.validate(command: "reference", options: ["suggest", "--library", ReferenceLibrary.primaryID.uuidString, "--context", factContext])
rejects("Citation CLI bounds the sentence context") { try EditorCLIArguments.validate(command: "reference", options: ["suggest", "--library", ReferenceLibrary.primaryID.uuidString, "--context", String(repeating: "x", count: 1201)]) }
let onlineAbstract = try ReferencePaperLookup.parseCrossref(Data(#"{"message":{"title":["Test paper"],"abstract":"<jats:p>Ammonia &amp; hydrogen.</jats:p>"}}"#.utf8), single: true)
try check(onlineAbstract.first?.fields["abstract"] == "Ammonia & hydrogen.", "Crossref abstracts are retained as plain text for local retrieval")
print("Passed \(checks) Reference checks including local citation relevance")

let relevanceRepository = ReferenceRepository(root: output.appendingPathComponent("relevance-cli"))
let emptyVersion = relevanceRepository.version()
let insertedRelevance = try relevanceRepository.add([trendPaper, chemistryPaper, unrelatedPaper])
try check(relevanceRepository.version() != emptyVersion, "Catalogue changes invalidate prepared citation snapshots without scanning PDFs")
let cliRank = try ReferenceCLI.response(["suggest", "--library", ReferenceLibrary.primaryID.uuidString, "--context", factContext], repository: relevanceRepository)
let cliFirst = (cliRank["suggestions"] as? [[String: Any]])?.first
try check(cliFirst?["title"] as? String == chemistryPaper.title, "CLI uses the same contextual ordering as the editor")
let cliAssessment = cliFirst?["relevance"] as? [String: Any]
try check(cliAssessment?["verified"] as? Bool == false && cliAssessment?["basis"] as? String == "Title and abstract", "CLI exposes source basis without claiming verification")
let longAbstract = String(repeating: "Hydrogen pressure. ", count: 1500)
let unmodifiedSource = ReferenceRecord(key: "Unmodified", fields: ["title": "Hydrogen pressure", "abstract": longAbstract])
try check(ReferenceCitationIndex([unmodifiedSource]).entries[0].record.fields["abstract"] == longAbstract, "Index budgets never truncate the record later inserted into a bibliography")
try check(ReferenceRelevance.tokens("3% error with pressure").contains("pressure"), "Percentages in metadata do not swallow later text")
let performanceRecords = (0..<1000).map { n in ReferenceRecord(key: "Bench\(n)", fields: ["title": n.isMultiple(of: 5) ? "Hydrogen ignition and pressure" : "Unrelated galaxies", "abstract": "Synthetic data for local retrieval timing."]) }
let prepareStart = Date()
let performanceIndex = ReferenceCitationIndex(performanceRecords)
let preparedIn = Date().timeIntervalSince(prepareStart)
let queryStart = Date()
for _ in 0..<20 { _ = ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: performanceIndex, context: factContext) }
print("Local relevance timing, 1000 synthetic records: prepare \(preparedIn)s, mean request \(Date().timeIntervalSince(queryStart) / 20)s")
print("Passed \(checks) Reference checks including CLI and index preservation")

for command in ["cite", "citep", "citet", "parencite", "textcite", "autocite", "footcite", "smartcite", "nocite"] {
    let text = "Hydrogen ignition depends on pressure \\" + command + "{NotContext"
    let value = ReferenceRelevance.sentence(text, before: text.utf16.count)
    try check(!value.contains("NotContext") && value.contains("Hydrogen"), "All supported citation commands exclude their key query from context")
}
print("Passed \(checks) Reference checks including supported citation syntax")

var sharedSource = trendPaper
sharedSource.fields["doi"] = "10.1234/shared"
sharedSource.fields["author"] = "Example, Author"; sharedSource.fields["year"] = "2025"
var sparseProject = sharedSource; sparseProject.fields.removeValue(forKey: "abstract")
let enrichedProject = ReferenceCitationCompletion.suggestions(query: "", project: [sparseProject], library: [sharedSource], context: trendContext)
try check(enrichedProject.count == 1 && enrichedProject[0].project && enrichedProject[0].relevance?.basis == "Title and abstract", "An identified project source can use its selected-library abstract without adding another bibliography entry")
try check(enrichedProject[0].record.fields["abstract"] == nil, "Using a library abstract for ranking does not rewrite project metadata")
let abstractQuery = ReferenceCitationCompletion.suggestions(query: "neural networks", project: [sparseProject], library: [sharedSource], context: trendContext)
try check(abstractQuery.first?.project == true, "Abstract queries still select the existing project entry")
var keyCollision = sharedSource; keyCollision.fields["doi"] = "10.1234/different"; keyCollision.fields["title"] = "Different scientific study"
let refusedBorrow = ReferenceCitationCompletion.suggestions(query: "", project: [sparseProject], library: [keyCollision], context: trendContext)
try check(refusedBorrow[0].relevance?.basis == "Title only", "A matching citation key cannot attach an unrelated abstract")
var bibliographicMatch = sharedSource; bibliographicMatch.fields.removeValue(forKey: "doi")
var bibliographicProject = sparseProject; bibliographicProject.fields.removeValue(forKey: "doi")
try check(ReferenceRelevance.sameSource(bibliographicMatch, bibliographicProject), "Exact title, authors and year can link metadata without identifiers")
bibliographicMatch.fields["author"] = "Someone else"
try check(!ReferenceRelevance.sameSource(bibliographicMatch, bibliographicProject), "A title alone cannot link another paper's abstract")
print("Passed \(checks) Reference checks including project/library identity")


// Edited volumes retain their contributor roles in parsing, display and keys.
let compactColumns = ReferenceColumn.visible(ReferenceColumn.defaults)
let compactWidths = ReferenceColumnWidths.fitted(available: 666, columns: compactColumns, saved: [:])
try check(compactColumns.reduce(130.0) { $0 + (compactWidths[$1.rawValue] ?? 0) } <= 666.01, "Default columns fit a normal three-pane Reference workspace")
let manualWidths = ReferenceColumnWidths.fitted(available: 500, columns: compactColumns, saved: ["title": 430, "publication": 240])
try check(manualWidths["title"] == 180 && manualWidths["publication"] == 120, "Below the minimum readable width, manual columns stop at readable floors")
let wideWidths = ReferenceColumnWidths.fitted(available: 1200, columns: compactColumns, saved: [:])
try check(wideWidths["publication"] == ReferenceColumn.publication.width && wideWidths["title"]! > compactWidths["title"]!, "Wide layouts restore full automatic column widths")

let editedBookJSON = #"{"message":{"type":"edited-book","title":["Data-Driven Fluid Mechanics: Combining First Principles and Machine Learning"],"editor":[{"family":"Mendez","given":"Miguel A."},{"family":"Ianiro","given":"Andrea"},{"family":"Noack","given":"Bernd R."},{"family":"Brunton","given":"Steven L."}],"DOI":"10.1017/9781108896214","publisher":"Cambridge University Press","published-print":{"date-parts":[[2023,1,12]]},"ISBN":["9781108896214"]}}"#
let editedVolume = try ReferencePaperLookup.parseCrossref(Data(editedBookJSON.utf8), single: true)[0]
try check(editedVolume.type == "book" && editedVolume.authors.isEmpty && ReferenceText.authors(editedVolume.editors).count == 4, "Crossref edited volumes preserve editors without inventing authors")
try check(ReferenceKeyRule.surnameYearWord.key(for: editedVolume) == "Mendez_2023_Data", "Editor-only volumes use the first editor's surname for new citation keys")
try check(ReferenceColumn.author.label == "Author / Editor" && ReferenceColumn.author.value(editedVolume) == "Mendez et al. (eds.)", "Contributor column identifies an edited volume and does not stay empty")
try check(editedVolume.displayContributors.contains("(eds.)") && editedVolume.displayContributors.contains("Brunton"), "Citation metadata identifies all editors with their role")
let editedRows = ReferenceMetadata.rows(editedVolume)
try check(editedRows.contains { $0.label == "Editor" } && !editedRows.contains { $0.label == "Author" }, "Metadata inspector keeps editor and author fields separate")
let volumeBib = try ReferenceBibTeX.export([editedVolume])
try check(volumeBib.contains("editor =") && !volumeBib.contains("author ="), "Edited book export keeps the editor field rather than relabelling it")
var authoredVolume = editedVolume; authoredVolume.fields["author"] = "Writer, Actual"
try check(ReferenceKeyRule.surnameYearWord.key(for: authoredVolume) == "Writer_2023_Data" && !authoredVolume.displayContributors.contains("(eds.)"), "A real author takes precedence when both roles exist")
var singleEditor = editedVolume; singleEditor.fields["editor"] = "Mendez, Miguel A."
try check(singleEditor.shortContributors == "Mendez (ed.)", "Single-editor display uses the singular role")
var missingAuthor = editedVolume; missingAuthor.fields["author"] = "  "
try check(missingAuthor.usesEditors && ReferenceKeyRule.surnameYearWord.key(for: missingAuthor) == "Mendez_2023_Data", "Whitespace-only authors fall back to editors")
var unidentifiableVolume = editedVolume; unidentifiableVolume.fields.removeValue(forKey: "editor")
try check(ReferenceKeyRule.surnameYearWord.key(for: unidentifiableVolume) == "Reference_2023_Data", "A genuinely unknown contributor remains explicit")
let editedCandidates = ReferenceCitationCompletion.suggestions(query: "Ianiro", project: [], library: [editedVolume])
try check(editedCandidates.count == 1, "Editors are searchable in citation completion")
var editedProject = editedVolume; editedProject.fields.removeValue(forKey: "doi")
var editedLibrary = editedProject; editedLibrary.fields["abstract"] = "Turbulent combustion and machine learning."
try check(ReferenceRelevance.sameSource(editedProject, editedLibrary), "Matching title, editors and year can link a project source to its abstract")
var incorrectRole = editedProject; incorrectRole.fields["author"] = incorrectRole.fields.removeValue(forKey: "editor")
try check(!ReferenceRelevance.sameSource(editedProject, incorrectRole), "Equal names in different contributor roles are not treated as a bibliographic identity")
let keyPreservingBook = try ReferenceRecognition.merged(ReferenceRecord(key: "Reference_2023_Data", type: "book", fields: ["title": editedVolume.title, "doi": editedVolume.fields["doi"]!]), with: editedVolume)
try check(keyPreservingBook.key == "Reference_2023_Data" && !keyPreservingBook.editors.isEmpty, "Metadata enrichment preserves existing manuscript keys while adding editors")
let editorRepository = ReferenceRepository(root: output.appendingPathComponent("edited-books"), keyRule: .surnameYearWord)
let savedVolume = try editorRepository.add([editedVolume])[0]
try check(savedVolume.citationKey == "Mendez_2023_Data", "New library imports generate contributor-aware keys")
let editorCLI = try ReferenceCLI.response(["suggest", "--library", savedVolume.library.uuidString, "--query", "Mendez"], repository: editorRepository)
let editorPayload = (editorCLI["suggestions"] as? [[String: Any]])?.first
try check(editorPayload?["authors"] as? String == "" && (editorPayload?["editors"] as? String)?.contains("Mendez") == true && editorPayload?["contributorRole"] as? String == "editor", "CLI exposes editors separately from authors")
print("Passed \(checks) Reference checks including edited books")

let expandedColumns = ReferenceColumnWidths.fitted(available: 1800, columns: compactColumns, saved: ["title": 300])
try check(abs(compactColumns.reduce(130.0) { $0 + (expandedColumns[$1.rawValue] ?? 0) } - 1800) < 0.01 && expandedColumns["publication"]! > 150, "A manual Title width leaves remaining space to automatic metadata columns")

let keyEditRepository = ReferenceRepository(root: root.appendingPathComponent("manual-key-edit"), history: ReferenceRepository.History())
var keyEditSource = ReferenceRecord(); keyEditSource.fields = ["title": "Manual key fixture", "author": "Example", "year": "2026", "journal": "Fixture journal"]
let keyEditOriginal = try keyEditRepository.add([keyEditSource])[0]
var keyEditDraft = keyEditOriginal; keyEditDraft.key = "Chosen_2026"
let keyEditSaved = try keyEditRepository.update(keyEditDraft, expected: keyEditDraft.revision, renameKey: true)
try check(keyEditSaved.key == "Chosen_2026" && keyEditSaved.id == keyEditOriginal.id && keyEditSaved.fields == keyEditOriginal.fields, "Explicit key edit preserves identity and metadata")
try check(try ReferenceRepository(root: root.appendingPathComponent("manual-key-edit")).records()[0].key == "Chosen_2026", "Manual key survives reload")
for invalidKey in ["", " ", "bad key", "x,y", "x{y"] {
 var invalid = keyEditSaved; invalid.key = invalidKey
 rejects("Invalid manual key") { _ = try keyEditRepository.update(invalid, expected: invalid.revision, renameKey: true) }
}
var collisionSource = ReferenceRecord(); collisionSource.fields["title"] = "Collision fixture"
let collisionSaved = try keyEditRepository.add([collisionSource])[0]
var collisionEdit = collisionSaved; collisionEdit.key = "chosen_2026"
rejects("Manual key collision ignores case") { _ = try keyEditRepository.update(collisionEdit, expected: collisionEdit.revision, renameKey: true) }
let typeEdit = ReferenceKind.book.applying(to: keyEditSaved)
let typeSaved = try keyEditRepository.update(typeEdit, expected: typeEdit.revision)
try check(typeSaved.type == "book" && typeSaved.key == keyEditSaved.key && typeSaved.fields == keyEditSaved.fields, "Type edit preserves fields and key")
try keyEditRepository.undo()
try check(try keyEditRepository.records().first { $0.id == keyEditSaved.id }?.type == keyEditSaved.type, "Type edit supports undo")
print("Passed \(checks) Reference checks including manual key and type edits")
let beforeKeyRegeneration = try keyEditRepository.records().first { $0.id == keyEditSaved.id }!
_ = try keyEditRepository.regenerate(id: beforeKeyRegeneration.id, expected: beforeKeyRegeneration.revision, rule: .current)
let afterKeyRegeneration = try keyEditRepository.records().first { $0.id == keyEditSaved.id }!
try check(afterKeyRegeneration.key == ReferenceKeyRule.current.key(for: afterKeyRegeneration) && afterKeyRegeneration.key != "Chosen_2026", "Regeneration replaces a manual key using the current rule")
print("Passed \(checks) Reference checks including manual key regeneration")
var lockDraft = afterKeyRegeneration; lockDraft.citationKeyLocked = true
let lockedKeyRecord = try keyEditRepository.update(lockDraft, expected: lockDraft.revision)
try check(try ReferenceRepository(root: root.appendingPathComponent("manual-key-edit")).records().first { $0.id == lockedKeyRecord.id }?.citationKeyLocked == true, "Key lock survives reload")
var lockedManual = lockedKeyRecord; lockedManual.key = "Locked_manual"
let lockedManualSaved = try keyEditRepository.update(lockedManual, expected: lockedManual.revision, renameKey: true)
try check(lockedManualSaved.key == "Locked_manual" && lockedManualSaved.citationKeyLocked == true, "Locked key remains manually editable")
try check(try keyEditRepository.regenerate(id: lockedManualSaved.id, expected: lockedManualSaved.revision, rule: .current) == 0, "Individual regeneration skips locked keys")
_ = try keyEditRepository.regenerate(rule: .current)
let afterLockedBatch = try keyEditRepository.records().first { $0.id == lockedManualSaved.id }!
try check(afterLockedBatch.key == "Locked_manual", "Batch regeneration reserves and preserves locked keys")
var unlockedDraft = afterLockedBatch; unlockedDraft.citationKeyLocked = false
let unlockedSaved = try keyEditRepository.update(unlockedDraft, expected: unlockedDraft.revision)
_ = try keyEditRepository.regenerate(id: unlockedSaved.id, expected: unlockedSaved.revision, rule: .current)
try check(try keyEditRepository.records().first { $0.id == unlockedSaved.id }?.key != "Locked_manual", "Unlock restores regeneration")
print("Passed \(checks) Reference checks including key locks")
let batchInitial = try keyEditRepository.records()
try keyEditRepository.setKeyLock([batchInitial[0]], locked: true)
let batchMixed = try keyEditRepository.records()
try check(batchMixed.filter { $0.citationKeyLocked == true }.count == 1, "Mixed lock fixture")
try keyEditRepository.setKeyLock(batchMixed, locked: false)
try check(try keyEditRepository.records().allSatisfy { $0.citationKeyLocked != true }, "Batch unlock handles mixed states")
try keyEditRepository.undo()
try check(try keyEditRepository.records().filter { $0.citationKeyLocked == true }.count == 1, "Batch lock change undoes as one operation")
let batchBeforeLock = try keyEditRepository.records()
try keyEditRepository.setKeyLock(batchBeforeLock, locked: true)
let batchAllLocked = try keyEditRepository.records()
try check(batchAllLocked.allSatisfy { $0.citationKeyLocked == true }, "Batch lock handles mixed states")
let unchangedLocked = batchBeforeLock.first { $0.citationKeyLocked == true }!
try check(batchAllLocked.first { $0.id == unchangedLocked.id }?.revision == unchangedLocked.revision, "Already locked record retains its revision")
rejects("Stale batch lock is rejected atomically") { try keyEditRepository.setKeyLock(batchBeforeLock, locked: false) }
try check(try keyEditRepository.records() == batchAllLocked, "Failed batch leaves every selection unchanged")
print("Passed \(checks) Reference checks including mixed batch locks")
var editorRoundTrip = lockedManualSaved
editorRoundTrip.fields["abstract"] = "Stored abstract"
let editorBibTeX = try ReferenceBibTeX.export([editorRoundTrip])
try check(editorBibTeX.contains("@" + editorRoundTrip.type + "{" + editorRoundTrip.citationKey) && editorBibTeX.contains("Stored abstract"), "Editor BibTeX reflects current fields including abstract")
let editorDecoded = try ReferenceBibTeX.applying(editorBibTeX, to: editorRoundTrip)
try check(editorDecoded.id == editorRoundTrip.id && editorDecoded.revision == editorRoundTrip.revision && editorDecoded.citationKeyLocked == true && editorDecoded.attachments == editorRoundTrip.attachments && editorDecoded.library == editorRoundTrip.library, "BibTeX edits preserve record identity, lock and attachment ownership")
try check(editorDecoded.fields == editorRoundTrip.fields && editorDecoded.key == editorRoundTrip.key, "Details and BibTeX round trip")
let editorChanged = try ReferenceBibTeX.applying("@book{Changed_key,title={Changed title},editor={Example}}", to: editorRoundTrip)
try check(editorChanged.key == "Changed_key" && editorChanged.type == "book" && editorChanged.title == "Changed title" && editorChanged.citationKeyLocked == true, "BibTeX edits update key, type and metadata")
for invalidSource in ["", "@book{x,title={broken}", editorBibTeX + editorBibTeX.replacingOccurrences(of: editorRoundTrip.citationKey, with: "Another_key")] {
 rejects("Editor rejects invalid or multiple BibTeX entries") { _ = try ReferenceBibTeX.applying(invalidSource, to: editorRoundTrip) }
}
print("Passed \(checks) Reference checks including editor BibTeX")
