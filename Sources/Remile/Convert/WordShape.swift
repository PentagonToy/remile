import Foundation

/// Inline DrawingML shapes with explicit colours or a static freeform path.
enum WordShape {
    static func markup(_ node: WordXML.Node) throws -> String {
        guard node.descendants("anchor").isEmpty, node.descendants("txbxContent").isEmpty, let properties = node.descendants("spPr").first,
              let extent = node.descendants("extent").first, let cx = extent.attribute("cx").flatMap(Double.init), let cy = extent.attribute("cy").flatMap(Double.init), cx > 0, cy > 0,
              cx <= 24_000_000, cy <= 24_000_000 else { throw WordImages.Failure.feature("This Word shape cannot be rendered yet.") }
        func color(_ node: WordXML.Node?, fallback: String) throws -> String {
            guard let node else { return fallback }
            if node.child("noFill") != nil { return "none" }
            guard let value = node.child("solidFill")?.child("srgbClr")?.attribute("val"), value.count == 6, value.allSatisfy(\.isHexDigit), node.child("solidFill")?.child("srgbClr")?.children.isEmpty == true else { throw WordImages.Failure.feature("This Word shape colour is not supported yet.") }
            return "#" + value
        }
        guard properties.child("xfrm")?.attributes.keys.contains(where: { ["rot", "flipH", "flipV"].contains($0.split(separator: ":").last.map(String.init) ?? "") }) != true else { throw WordImages.Failure.unsupported }
        let fill: String
        if properties.child("noFill") != nil { fill = "none" }
        else if let solid = properties.child("solidFill") { let wrapper = WordXML.Node("fill"); wrapper.content = [.node(solid)]; fill = try color(wrapper, fallback: "none") }
        else { throw WordImages.Failure.feature("This Word shape fill is not supported yet.") }
        let stroke = try color(properties.child("ln"), fallback: "none")
        let shape: String
        let width = cx / 9525, height = cy / 9525
        if let preset = properties.child("prstGeom")?.attribute("prst") {
            switch preset {
            case "rect": shape = "<rect x='0' y='0' width='1000' height='1000'/>"
            case "roundRect": shape = "<rect x='0' y='0' width='1000' height='1000' rx='100'/>"
            case "ellipse": shape = "<ellipse cx='500' cy='500' rx='500' ry='500'/>"
            case "triangle": shape = "<path d='M500 0 L1000 1000 L0 1000 Z'/>"
            case "diamond": shape = "<path d='M500 0 L1000 500 L500 1000 L0 500 Z'/>"
            case "line": shape = "<path d='M0 0 L1000 1000'/>"
            default: throw WordImages.Failure.feature("Unsupported Word shape: \(preset).")
            }
        } else if let paths = properties.child("custGeom")?.child("pathLst")?.children, paths.count <= 32 {
            shape = try paths.map { path in
                guard let w = path.attribute("w").flatMap(Double.init), let h = path.attribute("h").flatMap(Double.init), w > 0, h > 0, w.isFinite, h.isFinite else { throw WordImages.Failure.unsupported }
                var result = "", count = 0
                for command in path.children {
                    count += 1; guard count <= 2000 else { throw WordImages.Failure.unsupported }
                    let expected = ["moveTo": 1, "lnTo": 1, "cubicBezTo": 3, "quadBezTo": 2, "close": 0]
                    guard expected[command.local] == command.children.count else { throw WordImages.Failure.unsupported }
                    let points = try command.children.map { point -> String in
                        guard let x = point.attribute("x").flatMap(Double.init), let y = point.attribute("y").flatMap(Double.init), x.isFinite, y.isFinite, abs(x) <= w * 10, abs(y) <= h * 10 else { throw WordImages.Failure.unsupported }
                        return "\(x * 1000 / w) \(y * 1000 / h)"
                    }.joined(separator: " ")
                    switch command.local {
                    case "moveTo": result += "M" + points
                    case "lnTo": result += "L" + points
                    case "cubicBezTo": result += "C" + points
                    case "quadBezTo": result += "Q" + points
                    case "close": result += "Z"
                    default: throw WordImages.Failure.feature("This Word freeform path is not supported yet.")
                    }
                }
                return "<path d='\(result)'/>"
            }.joined()
        } else { throw WordImages.Failure.unsupported }
        let strokeWidth = (properties.child("ln")?.attribute("w").flatMap(Double.init) ?? 9525) / 9525
        guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= 100 else { throw WordImages.Failure.unsupported }
        let artwork = ["path", "rect", "ellipse"].reduce(shape) { $0.replacingOccurrences(of: "<" + $1 + " ", with: "<" + $1 + " vector-effect='non-scaling-stroke' ") }
        return "<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)' viewBox='-5 -5 1010 1010' preserveAspectRatio='none'><g fill='\(fill)' stroke='\(stroke)' stroke-width='\(strokeWidth)'>\(artwork)</g></svg>"
    }
}
