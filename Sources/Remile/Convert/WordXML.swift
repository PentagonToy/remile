import Foundation

final class WordXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var content: [Content] = []
        enum Content { case text(String), node(Node) }
        init(_ name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
        var local: String { String(name.split(separator: ":").last ?? "") }
        var children: [Node] { content.compactMap { if case .node(let node) = $0 { return node }; return nil } }
        var text: String { content.map { if case .text(let text) = $0 { return text }; if case .node(let node) = $0 { return node.text }; return "" }.joined() }
        func attribute(_ name: String) -> String? { attributes.first { $0.key.split(separator: ":").last.map(String.init) == name }?.value }
        func child(_ name: String) -> Node? { children.first { $0.local == name } }
        func descendants(_ name: String) -> [Node] { children.flatMap { ($0.local == name ? [$0] : []) + $0.descendants(name) } }
        var xml: String { "<" + name + attributes.keys.sorted().map { " \($0)=\"\(MathMarkup.escape(attributes[$0]!))\"" }.joined() + ">" + content.map { if case .text(let text) = $0 { return MathMarkup.escape(text) }; if case .node(let node) = $0 { return node.xml }; return "" }.joined() + "</" + name + ">" }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var count = 0
    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 20 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw WordImages.Failure.unsupported }
        let delegate = WordXML(), parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), let root = delegate.root else { throw WordImages.Failure.unsupported }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard count <= 200000, stack.count < 128 else { parser.abortParsing(); return }
        let node = Node(name, attributes: attributes)
        if let parent = stack.last { parent.content.append(.node(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.content.append(.text(text)) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { if let text = String(data: data, encoding: .utf8) { stack.last?.content.append(.text(text)) } else { parser.abortParsing() } }
}
