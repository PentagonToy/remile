import Foundation
import Darwin

/// Coalesced membership changes, with no timer or retained list of file events.
final class DirectoryChanges {
    let events: AsyncStream<Void>
    private let source: DispatchSourceFileSystemObject
    init(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.source.data.intersection([.rename, .delete]).isEmpty { stream.continuation.finish() }
            else { stream.continuation.yield(()) }
        }
        source.setCancelHandler { Darwin.close(descriptor); stream.continuation.finish() }
        source.resume()
        stream.continuation.yield(()) // Include requests queued before the watcher was attached.
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}
