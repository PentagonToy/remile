import PDFKit
import CryptoKit

enum PDFSignatureSaveStatus { case unsigned, preserved, atRisk }

/// Compare form values/resources across an annotation rewrite, independent of object numbering.
enum PDFFormPreservation {
    static func hasDigitalSignature(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var permissions: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(catalog, "Perms", &permissions) { return true }
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        var remaining = 10_000
        func visit(_ list: CGPDFArrayRef, inheritedType: String? = nil, depth: Int = 0) -> Bool {
            guard depth < 32 else { return true }
            for index in 0..<CGPDFArrayGetCount(list) {
                remaining -= 1; guard remaining > 0 else { return true }
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(list, index, &field), let field else { continue }
                var name: UnsafePointer<CChar>?, value: CGPDFDictionaryRef?, children: CGPDFArrayRef?
                let type = CGPDFDictionaryGetName(field, "FT", &name) ? name.map { String(cString: $0) } : inheritedType
                if type == "Sig", CGPDFDictionaryGetDictionary(field, "V", &value), let value {
                    var entry: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(value, "ByteRange", &entry) || CGPDFDictionaryGetObject(value, "Contents", &entry) { return true }
                }
                if CGPDFDictionaryGetArray(field, "Kids", &children), let children, visit(children, inheritedType: type, depth: depth + 1) { return true }
            }
            return false
        }
        return visit(fields)
    }


    static func snapshot(_ document: PDFDocument) throws -> String? {
        guard let catalog = document.documentRef?.catalog else { throw PDFReplyWriter.Failure.unsupported }
        var form: CGPDFObjectRef?, permissions: CGPDFObjectRef?
        let hasForm = CGPDFDictionaryGetObject(catalog, "AcroForm", &form)
        let hasPermissions = CGPDFDictionaryGetObject(catalog, "Perms", &permissions)
        guard hasForm || hasPermissions else { return nil }
        let encoder = Encoder()
        return try [form, permissions].map { try $0.map { try encoder.object($0) } ?? "null" }.joined(separator: "|")
    }
    private final class Entries { var values: [String: CGPDFObjectRef] = [:] }
    private final class Encoder {
        var remaining = 200_000
        var ancestors = Set<UInt>()
        func object(_ value: CGPDFObjectRef, key: String = "", depth: Int = 0) throws -> String {
            remaining -= 1
            guard remaining > 0, depth < 64 else { throw PDFReplyWriter.Failure.unsupported }
            switch CGPDFObjectGetType(value) {
            case .null: return "null"
            case .boolean:
                var result: CGPDFBoolean = 0; guard CGPDFObjectGetValue(value, .boolean, &result) else { throw PDFReplyWriter.Failure.unsupported }; return result == 0 ? "false" : "true"
            case .integer:
                var result: CGPDFInteger = 0; guard CGPDFObjectGetValue(value, .integer, &result) else { throw PDFReplyWriter.Failure.unsupported }; return String(format: "%.12g", Double(result))
            case .real:
                var result: CGPDFReal = 0; guard CGPDFObjectGetValue(value, .real, &result), result.isFinite else { throw PDFReplyWriter.Failure.unsupported }; return String(format: "%.12g", Double(result))
            case .name:
                var result: UnsafePointer<CChar>?; guard CGPDFObjectGetValue(value, .name, &result), let result else { throw PDFReplyWriter.Failure.unsupported }; return "name:" + quote(String(cString: result))
            case .string:
                var result: CGPDFStringRef?; guard CGPDFObjectGetValue(value, .string, &result), let result else { throw PDFReplyWriter.Failure.unsupported }
                if key != "Contents", let text = CGPDFStringCopyTextString(result) { return "text:" + quote(text as String) }
                guard let bytes = CGPDFStringGetBytePtr(result) else { return "bytes:" }
                return "bytes:" + digest(Data(bytes: bytes, count: CGPDFStringGetLength(result)))
            case .array:
                var result: CGPDFArrayRef?; guard CGPDFObjectGetValue(value, .array, &result), let result else { throw PDFReplyWriter.Failure.unsupported }
                return try (0..<CGPDFArrayGetCount(result)).map { index in
                    var child: CGPDFObjectRef?; guard CGPDFArrayGetObject(result, index, &child), let child else { throw PDFReplyWriter.Failure.unsupported }
                    return try object(child, key: key, depth: depth + 1)
                }.joined(separator: ",").wrapped("[", "]")
            case .dictionary:
                var result: CGPDFDictionaryRef?; guard CGPDFObjectGetValue(value, .dictionary, &result), let result else { throw PDFReplyWriter.Failure.unsupported }
                return try dictionary(result, depth: depth)
            case .stream:
                var result: CGPDFStreamRef?; guard CGPDFObjectGetValue(value, .stream, &result), let result else { throw PDFReplyWriter.Failure.unsupported }
                var format = CGPDFDataFormat.raw
                guard let data = CGPDFStreamCopyData(result, &format), CFDataGetLength(data) <= 10_000_000 else { throw PDFReplyWriter.Failure.unsupported }
                return "stream:" + digest(data as Data)
            @unknown default: throw PDFReplyWriter.Failure.unsupported
            }
        }
        func dictionary(_ dictionary: CGPDFDictionaryRef, depth: Int) throws -> String {
            let identity = UInt(bitPattern: dictionary.rawValue)
            guard ancestors.insert(identity).inserted else { throw PDFReplyWriter.Failure.unsupported }
            defer { ancestors.remove(identity) }
            let entries = Entries()
            CGPDFDictionaryApplyFunction(dictionary, { key, value, context in
                guard let context else { return }; Unmanaged<Entries>.fromOpaque(context).takeUnretainedValue().values[String(cString: key)] = value
            }, Unmanaged.passUnretained(entries).toOpaque())
            // Back-references and annotation IDs may be rewritten without changing field values.
            return try entries.values.keys.filter { !["P", "Parent", "NM"].contains($0) }.sorted().map { key in
                quote(key) + ":" + (try object(entries.values[key]!, key: key, depth: depth + 1))
            }.joined(separator: ",").wrapped("{", "}")
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func quote(_ value: String) -> String { String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) }
    }
}

private extension String { func wrapped(_ prefix: String, _ suffix: String) -> String { prefix + self + suffix } }
