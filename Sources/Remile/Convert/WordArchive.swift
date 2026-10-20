import Foundation
import zlib

/// Bounded ZIP access for OOXML; entries stay in memory and never become filesystem paths.
struct WordArchive {
    struct Entry { let name: String; let method: UInt16; let crc: UInt32; let size: Int; let compressed: Data }
    let entries: [Entry]
    enum Failure: LocalizedError {
        case invalid, limit
        var errorDescription: String? { self == .limit ? "This Word document is too large." : "Unsupported or damaged Word document." }
    }
    init(_ bytes: Data) throws {
        guard bytes.count <= 64 * 1024 * 1024, bytes.count >= 22 else { throw Failure.limit }
        func word(_ offset: Int) throws -> Int { guard offset >= 0, offset + 2 <= bytes.count else { throw Failure.invalid }; return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func long(_ offset: Int) throws -> Int { try word(offset) | word(offset + 2) << 16 }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try long(offset) == 0x06054b50, try offset + 22 + word(offset + 20) == bytes.count { end = offset; break }
        }
        guard let end, try word(end + 4) == 0, try word(end + 6) == 0, try word(end + 8) == word(end + 10) else { throw Failure.invalid }
        let count = try word(end + 10), central = try long(end + 16), centralSize = try long(end + 12)
        guard count > 0, count <= 1024, central >= 0, central + centralSize <= end else { throw Failure.limit }
        var offset = central, records: [Entry] = [], names = Set<String>(), total = 0
        for _ in 0..<count {
            guard try long(offset) == 0x02014b50 else { throw Failure.invalid }
            let flags = try word(offset + 8), method = try word(offset + 10), crc = try long(offset + 16)
            let compressed = try long(offset + 20), size = try long(offset + 24), nameLength = try word(offset + 28)
            let extra = try word(offset + 30), comment = try word(offset + 32), local = try long(offset + 42)
            guard flags & 1 == 0, [0, 8].contains(method), size <= 30 * 1024 * 1024,
                  offset + 46 + nameLength + extra + comment <= central + centralSize,
                  let name = String(data: bytes.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8), names.insert(name).inserted,
                  try long(local) == 0x04034b50, try word(local + 8) == method else { throw Failure.invalid }
            let start = try local + 30 + word(local + 26) + word(local + 28)
            guard start >= 0, start + compressed <= central else { throw Failure.invalid }
            total += size; guard total <= 100 * 1024 * 1024 else { throw Failure.limit }
            records.append(Entry(name: name, method: UInt16(method), crc: UInt32(crc), size: size, compressed: bytes.subdata(in: start..<start + compressed)))
            offset += 46 + nameLength + extra + comment
        }
        guard offset == central + centralSize else { throw Failure.invalid }
        entries = records
    }
    func read(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw Failure.invalid }
        var result: Data
        if entry.method == 0 { result = entry.compressed }
        else {
            result = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
            defer { inflateEnd(&stream) }
            let status = result.withUnsafeMutableBytes { output in
                entry.compressed.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == entry.compressed.count else { throw Failure.invalid }
            result.count = entry.size
        }
        let crc = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard result.count == entry.size, UInt32(crc) == entry.crc else { throw Failure.invalid }
        return result
    }
    func replacing(_ name: String, with replacement: Data) -> Data {
        var output = Data(), central = Data()
        func append(_ number: Int, bytes: Int, to data: inout Data) { for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: number >> (index * 8))) } }
        for entry in entries {
            let changed = entry.name == name, data = changed ? replacement : entry.compressed
            let crc = changed ? replacement.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) } : entry.crc
            let method = changed ? 0 : Int(entry.method), size = changed ? replacement.count : entry.size
            let filename = Data(entry.name.utf8), start = output.count
            append(0x04034b50, bytes: 4, to: &output)
            for value in [20, 0x800, method, 0, 0] { append(value, bytes: 2, to: &output) }
            for value in [Int(crc), data.count, size] { append(value, bytes: 4, to: &output) }
            append(filename.count, bytes: 2, to: &output); append(0, bytes: 2, to: &output)
            output.append(filename); output.append(data)
            append(0x02014b50, bytes: 4, to: &central)
            for value in [20, 20, 0x800, method, 0, 0] { append(value, bytes: 2, to: &central) }
            for value in [Int(crc), data.count, size] { append(value, bytes: 4, to: &central) }
            for value in [filename.count, 0, 0, 0, 0] { append(value, bytes: 2, to: &central) }
            append(0, bytes: 4, to: &central); append(start, bytes: 4, to: &central); central.append(filename)
        }
        let start = output.count; output.append(central)
        append(0x06054b50, bytes: 4, to: &output)
        for value in [0, 0, entries.count, entries.count] { append(value, bytes: 2, to: &output) }
        append(central.count, bytes: 4, to: &output); append(start, bytes: 4, to: &output); append(0, bytes: 2, to: &output)
        return output
    }
}
