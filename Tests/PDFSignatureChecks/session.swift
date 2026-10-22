import AppKit
import PDFKit

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
Task { @MainActor in
    do {
        _ = NSApplication.shared
        let original = try Data(contentsOf: output.appendingPathComponent("signed-p3.pdf"))
        let destination = output.appendingPathComponent("session-save.pdf")
        try original.write(to: destination)
        let reader = ReadingSession(); try reader.open(destination, recordRecent: false)
        let session = PDFSession(); session.load(original)
        let document = session.document!, page = document.page(at: 1)!
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); view.document = document; session.attach(view); view.go(to: page)
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        reader.pdfSession = session
        session.toggleEditing()
        expect(!session.isEditing && session.protection.attempts == 1, "Entering Edit PDF is blocked and shakes the lock before consent")
        let points = [CGPoint(x: 60, y: 520), CGPoint(x: 100, y: 550), CGPoint(x: 170, y: 530)]
        let blocked = PDFDrawingTool.rectangle.annotation(points: points, on: page, color: .red)!
        session.addDrawing(blocked, on: page)
        expect(session.protection.isLocked && session.protection.attempts == 2 && !session.hasPendingAnnotations, "Signed reader edits are blocked and shake the lock")
        try session.protection.authorise(data: original)
        session.toggleEditing()
        expect(session.isEditing && session.canArrangePages, "Explicit consent permits entering Edit PDF")
        let firstSnapshot = session.protection.snapshotURL!
        expect((try! Data(contentsOf: firstSnapshot)) == original, "Unlock keeps exactly the original PDF in a private temporary transaction")

        for tool in PDFDrawingTool.allCases {
            let note = tool.annotation(points: points, on: page, color: .systemRed)!
            undo.beginUndoGrouping(); session.addDrawing(note, on: page); undo.endUndoGrouping()
            expect(session.editingError == nil, "Drawing commits")
            expect(session.hasPendingAnnotations && session.committedData == nil, "Individual strokes create no full PDF byte snapshot")
            undo.undo(); expect(!page.annotations.contains { $0 === note }, "Drawing undo removes annotation")
            undo.redo(); expect(page.annotations.contains { $0 === note }, "Drawing redo restores annotation")
        }
        expect(session.protection.snapshotURL == firstSnapshot, "All strokes reuse one original snapshot")
        expect(reader.dirty, "Pending annotations mark the canonical document dirty without serialising it")
        reader.document.content = .pdf(try session.prepareSave())
        expect(session.signatureSaveStatus(for: reader.bytes) == .preserved, "Save produces a signature-preserving proof")
        expect(!reader.signatureSaveNeedsWarning(reader.bytes), "Verified annotation save needs no warning")
        expect(reader.save() && !reader.dirty, "Verified annotation overwrites the same file through canonical Save")
        expect(!FileManager.default.fileExists(atPath: firstSnapshot.path) && session.protection.snapshotURL == nil, "Save removes the temporary original")
        var saved = try Data(contentsOf: destination)
        expect(saved.starts(with: original), "Canonical Save leaves signed bytes untouched")
        let committedBeforeStroke = session.committedData
        let additional = PDFDrawingTool.ellipse.annotation(points: points, on: page, color: .blue)!
        undo.beginUndoGrouping(); session.addDrawing(additional, on: page); undo.endUndoGrouping()
        expect(session.committedData == committedBeforeStroke && (try! Data(contentsOf: destination)) == saved, "A later stroke creates neither a replacement buffer nor a disk write")
        expect(reader.save(), "A second annotation save remains signature-preserving")
        saved = try Data(contentsOf: destination)
        let rotatedPage = view.currentPage!
        undo.beginUndoGrouping(); session.rotateCurrentPage(clockwise: true); undo.endUndoGrouping()
        expect(session.editingError == nil && rotatedPage.rotation == 90, "Page rotation is allowed before Save: \(session.editingError ?? "no error"), angles \(PDFPageAssembly.pages(session.document!).map(\.rotation))")
        reader.document.content = .pdf(session.committedData!)
        expect(reader.signatureSaveNeedsWarning(reader.bytes), "Rotation requires an explicit signature-risk choice at Save")
        expect(try! Data(contentsOf: destination) == saved, "Risky edits remain in memory before Save")
        reader.discardPDFChanges()
        expect(!reader.dirty && reader.bytes == saved, "Discard restores the saved version and clears dirty state")
        session.load(saved); view.document = session.document; view.go(to: session.document!.page(at: 0)!)
        let restored = session.document!
        let restoredView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); restoredView.document = restored; session.attach(restoredView)
        let insert = PDFDocument(); insert.insert(PDFPage(), at: 0)
        let insertURL = output.appendingPathComponent("insert.pdf"); try insert.dataRepresentation()!.write(to: insertURL)
        try session.protection.authorise(data: saved)
        let discardedSnapshot = session.protection.snapshotURL!
        undo.beginUndoGrouping(); session.insertPDFs([insertURL]); undo.endUndoGrouping()
        expect(session.editingError == nil && session.document!.pageCount == 3, "An unsigned page can be added to a signed PDF")
        expect(session.signatureSaveStatus(for: session.committedData!) == .atRisk, "Page addition cannot reuse an annotation preservation proof")
        reader.document.content = .pdf(session.committedData!)
        expect(reader.signatureSaveNeedsWarning(reader.bytes), "Page addition requires warning at Save")
        reader.discardPDFChanges()
        expect(!FileManager.default.fileExists(atPath: discardedSnapshot.path), "Discard removes the snapshot and leaves the saved PDF in place")
        let locked = try Data(contentsOf: output.appendingPathComponent("signed-p1.pdf"))
        let restricted = PDFSession(); restricted.load(locked); restricted.toggleEditing(); try restricted.protection.authorise(data: locked); restricted.toggleEditing()
        let square = PDFDrawingTool.rectangle.annotation(points: points, on: restricted.document!.page(at: 0)!, color: .red)!
        restricted.addDrawing(square, on: restricted.document!.page(at: 0)!)
        expect(restricted.editingError == nil && restricted.hasPendingAnnotations, "Disallowed-by-certification markup may be prepared for user review")
        _ = try restricted.prepareSave()
        expect(restricted.signatureSaveStatus(for: restricted.committedData!) == .atRisk, "Restricted markup is never falsely attested as signature-preserving")
        let damagedData = try Data(contentsOf: output.appendingPathComponent("damaged.pdf"))
        let damagedSession = PDFSession(); damagedSession.load(damagedData); damagedSession.toggleEditing(); try damagedSession.protection.authorise(data: damagedData); damagedSession.toggleEditing()
        let damagedPage = damagedSession.document!.page(at: 0)!
        damagedSession.addDrawing(PDFDrawingTool.rectangle.annotation(points: points, on: damagedPage, color: .red)!, on: damagedPage)
        let damagedOutput = try damagedSession.prepareSave()
        expect(damagedSession.signatureSaveStatus(for: damagedOutput) == .atRisk, "An already damaged signature triggers the save-risk path")
        let detached = ReadingSession(), detachedURL = output.appendingPathComponent("detached.pdf")
        try locked.write(to: detachedURL); try detached.open(detachedURL, recordRecent: false)
        detached.document.content = .pdf(restricted.committedData!)
        expect(detached.signatureSaveNeedsWarning(detached.bytes), "Missing reader proof conservatively warns on changed signed PDFs")
        detached.discardPDFChanges()
        expect(!detached.signatureSaveNeedsWarning(detached.bytes), "Unchanged signed PDF needs no warning")
        let blankSession = PDFSession(); blankSession.load(insert.dataRepresentation()!)
        expect(!blankSession.protection.requiresConsent && !blankSession.protection.authorised && !blankSession.protection.isLocked, "An ordinary PDF starts unprotected without pretending the user unlocked it")
        let encrypted = PDFSession(); encrypted.load(insert.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"])!)
        try encrypted.protection.authorise(data: insert.dataRepresentation()!)
        encrypted.toggleEditing()
        expect(encrypted.protection.restricted && encrypted.protection.isLocked && !encrypted.protection.authorised && !encrypted.isEditing, "Consent cannot override encryption or enter editing")
        blankSession.insertPDFs([output.appendingPathComponent("signed-p0.pdf")])
        expect(blankSession.protection.isLocked, "Importing signed pages requests consent before mutation")
        try blankSession.protection.authorise(data: insert.dataRepresentation()!)
        blankSession.insertPDFs([output.appendingPathComponent("signed-p0.pdf")])
        expect(blankSession.editingError == nil && blankSession.signatureSaveStatus(for: blankSession.committedData!) == .atRisk, "Importing signed pages into an unsigned document also records signature risk")
        session.protection.finish(); restricted.protection.finish(); damagedSession.protection.finish(); blankSession.protection.finish()
        print("\(checks) signed-PDF session/save checks passed. Risk confirmation dialog is not automatically accepted.")
        exit(0)
    } catch { print("Signature session checks failed: \(error)"); exit(1) }
}
RunLoop.main.run()
