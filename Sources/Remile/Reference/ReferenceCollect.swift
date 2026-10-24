import Foundation

/// The same explicit, local collection operation is used by Search and the CLI.
enum ReferenceCollect {
    static func save(_ source: URL, library: UUID, repository: ReferenceRepository = ReferenceRepository()) throws -> ReferenceRecord {
        guard source.isFileURL, source.pathExtension.lowercased() == "pdf" else { throw ReferenceFailure("Choose a PDF to save as a reference.") }
        guard let record = try repository.importFiles([source], libraryID: library, matchingExisting: true, rejectAmbiguous: true).first else { throw ReferenceFailure("Could not save this reference.") }
        return record
    }
}
