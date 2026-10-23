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
try check(ReferenceKeyRule.surnameYearWord.key(for: parsed[0]) == "Kang_2026_A", "Surname/year/first word")
try check(ReferenceKeyRule.surnameYearTwoWords.key(for: parsed[0]) == "Kang_2026_A_Nested", "Surname/year/two words")
try check(ReferenceKeyRule.surnameYear.key(for: parsed[1]) == "Doe_2025", "Family name without comma")
var unknown = ReferenceRecord(); unknown.fields["title"] = "Uncertain title"
try check(ReferenceKeyRule.surnameYearWord.key(for: unknown) == "Reference_nd_Uncertain", "Unknown author/year are explicit")
var accents = parsed[0]; accents.fields["author"] = "García, Ana"; accents.fields["title"] = #"{\textit{École}} Study"#
try check(ReferenceKeyRule.surnameYearWord.key(for: accents) == "Garcia_2026_Ecole", "Portable keys remove TeX commands and accents")
for invalid in ["not BibTeX", "@article{x,title={Unclosed}", "@article{x,title=unknown}", "@article{x,title={a},title={b}}", "@article{x,title={a}} @article{x,title={b}}", "@article{x,title=}", "@article{x,title={a} year={2026}}"] {
    rejects("Malformed bibliography") { _ = try ReferenceBibTeX.parse(invalid) }
}
let added = try repository.add(parsed)
try check(added[0].key == "Kang_2026_A", "Import uses the fixed preset")
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
let correction = try ReferenceCorrection.parse("```bibtex\n@article{repaired,title={Fixed title}}\n```")
try check(correction.title == "Fixed title", "GPT response parser accepts one fenced entry")
rejects("GPT multi-entry response") { _ = try ReferenceCorrection.parse(bib) }
rejects("GPT prose response") { _ = try ReferenceCorrection.parse("Here is a guess: @article{a,title={x}}") }
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
let samePDF = try repository.importFiles([pdfURL], libraryID: library.id).first!
try check(samePDF.attachments.first?.id == copy.attachments.first?.id, "Repeated PDF import reuses stored bytes")
let snapshots = try repository.records().filter { groups[copy.id]?.contains($0.id) == true }
try repository.merge(snapshots, preferred: attached.id, alignMetadata: false)
rejects("Stale duplicate review") { try repository.merge(snapshots, preferred: attached.id, alignMetadata: false) }
try check(try repository.records().contains { $0.id == copy.id && $0.trashed == nil }, "Merge keeps membership in other libraries")
let currentGroup = ReferenceDuplicates.lookup(try repository.records())[samePDF.id]!
let currentSnapshots = try repository.records().filter { currentGroup.contains($0.id) }
try repository.merge(currentSnapshots, preferred: attached.id, alignMetadata: true)
try check(try repository.records().filter { $0.library == library.id && $0.trashed == nil }.count == 1, "Merge moves same-library extras to Trash")
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
try check(!ReferenceMetadata.rows(withAbstract).contains { $0.id == "abstract" }, "Metadata view hides abstract")
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
print("Passed \(checks) Reference checks including display spacing")

var venue = ReferenceRecord(); venue.fields = ["journal": "{{Combustion}} and Flame", "publisher": "Elsevier"]
try check(ReferenceColumn.publication.value(venue) == "Combustion and Flame", "Venue column prefers the journal over its publisher")
venue.fields["journal"] = " "
try check(ReferenceColumn.publication.value(venue) == "Elsevier", "Venue column falls back to publisher when journal is blank")
venue.fields["booktitle"] = "Annual Conference"
try check(ReferenceColumn.publication.value(venue) == "Annual Conference", "Conference venue precedes publisher")
try check(ReferenceColumn.visible(ReferenceColumn.defaults) == [.title, .author, .publication, .year], "New default includes the optional venue column before year")
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
print("Passed \(checks) Reference checks including durable PDF passages")
