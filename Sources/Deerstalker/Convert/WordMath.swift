import Foundation

/// The supported Office Math structures map to native MathML, never executable markup.
enum WordMath {
    static func markup(_ root: WordXML.Node, integralLimits: String = "subSup", naryLimits: String = "undOvr") throws -> String {
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mrow>" + (try Renderer(integralLimits: integralLimits, naryLimits: naryLimits).render(root)) + "</mrow></math>"
    }
    private struct Renderer {
        let integralLimits: String
        let naryLimits: String
        func render(_ node: WordXML.Node) throws -> String {
            func child(_ name: String) throws -> String { guard let value = node.child(name) else { throw WordImages.Failure.feature("Invalid Word equation.") }; return try render(value) }
            func sequence() throws -> String { try node.children.filter { !$0.local.hasSuffix("Pr") }.map(render).joined() }
            func property(_ group: String, _ name: String, _ fallback: String) -> String { node.child(group)?.child(name)?.attribute("val") ?? fallback }
            switch node.local {
            case "oMath", "oMathPara", "e", "num", "den", "sub", "sup", "deg", "fName", "lim", "mr": return "<mrow>" + (try sequence()) + "</mrow>"
            case "box": return try child("e")
            case "borderBox":
                func enabled(_ name: String) -> Bool {
                    guard let value = node.child("borderBoxPr")?.child(name) else { return false }
                    return !["0", "false", "off"].contains(value.attribute("val") ?? "1")
                }
                var edges: [String] = []
                for (hidden, notation) in [("hideTop", "top"), ("hideBot", "bottom"), ("hideLeft", "left"), ("hideRight", "right")] { if !enabled(hidden) { edges.append(notation) } }
                for (strike, notation) in [("strikeH", "horizontalstrike"), ("strikeV", "verticalstrike"), ("strikeBLTR", "updiagonalstrike"), ("strikeTLBR", "downdiagonalstrike")] { if enabled(strike) { edges.append(notation) } }
                return edges.isEmpty ? try child("e") : "<menclose notation=\"\(edges.joined(separator: " "))\">\(try child("e"))</menclose>"
            case "groupChr":
                let position = property("groupChrPr", "pos", "bot")
                guard ["top", "bot"].contains(position) else { throw WordImages.Failure.unsupported }
                let tag = position == "top" ? "mover" : "munder"
                let character = property("groupChrPr", "chr", "⏟")
                return "<\(tag)>\(try child("e"))<mo stretchy=\"true\">\(MathMarkup.escape(character))</mo></\(tag)>"
            case "phant":
                func enabled(_ name: String, fallback: Bool = false) -> Bool {
                    guard let value = node.child("phantPr")?.child(name) else { return fallback }
                    return !["0", "false", "off"].contains(value.attribute("val") ?? "1")
                }
                var body = try child("e")
                if !enabled("show", fallback: true) { body = "<mphantom>" + body + "</mphantom>" }
                var dimensions: [String] = []
                for (name, attribute) in [("zeroWid", "width"), ("zeroAsc", "height"), ("zeroDesc", "depth")] { if enabled(name) { dimensions.append(attribute + "=\"0\"") } }
                return dimensions.isEmpty ? body : "<mpadded \(dimensions.joined(separator: " "))>" + body + "</mpadded>"
            case "r":
                let style = node.child("rPr")?.child("sty")?.attribute("val") ?? "i"
                let variant = ["p": "normal", "b": "bold", "i": "italic", "bi": "bold-italic"][style] ?? "italic"
                return "<mstyle mathvariant=\"\(variant)\">" + (try sequence()) + "</mstyle>"
            case "t": return node.text.map { character in
                if character.isWhitespace { return "<mspace width=\"0.25em\"/>" }
                let tag = character.isNumber ? "mn" : character.isLetter ? "mi" : "mo"
                return "<\(tag)\(tag == "mi" ? "" : " mathvariant=\"normal\"")>" + MathMarkup.escape(String(character)) + "</\(tag)>"
            }.joined()
            case "f":
                let type = property("fPr", "type", "bar")
                guard ["bar", "noBar", "skw", "lin"].contains(type) else { throw WordImages.Failure.unsupported }
                if type == "lin" { return "<mrow>\(try child("num"))<mo>/</mo>\(try child("den"))</mrow>" }
                return "<mfrac\(type == "noBar" ? " linethickness=\"0\"" : type == "skw" ? " bevelled=\"true\"" : "")>\(try child("num"))\(try child("den"))</mfrac>"
            case "sSub": return "<msub>\(try child("e"))\(try child("sub"))</msub>"
            case "sSup": return "<msup>\(try child("e"))\(try child("sup"))</msup>"
            case "sSubSup": return "<msubsup>\(try child("e"))\(try child("sub"))\(try child("sup"))</msubsup>"
            case "sPre": return "<mmultiscripts>\(try child("e"))<mprescripts/>\(try child("sub"))\(try child("sup"))</mmultiscripts>"
            case "rad":
                let hidden = property("radPr", "degHide", "0")
                if ["1", "true", "on"].contains(hidden) || node.child("deg")?.text.isEmpty != false { return "<msqrt>\(try child("e"))</msqrt>" }
                return "<mroot>\(try child("e"))\(try child("deg"))</mroot>"
            case "d":
                let begin = property("dPr", "begChr", "("), end = property("dPr", "endChr", ")"), separator = property("dPr", "sepChr", "|")
                return "<mrow><mo stretchy=\"true\">\(MathMarkup.escape(begin))</mo>" + (try node.children.filter { $0.local == "e" }.map(render).joined(separator: "<mo>\(MathMarkup.escape(separator))</mo>")) + "<mo stretchy=\"true\">\(MathMarkup.escape(end))</mo></mrow>"
            case "nary":
                let character = property("naryPr", "chr", "∫")
                let low = property("naryPr", "subHide", "0"), high = property("naryPr", "supHide", "0")
                let lower = ["1", "true", "on"].contains(low) ? "<mrow/>" : (try child("sub"))
                let upper = ["1", "true", "on"].contains(high) ? "<mrow/>" : (try child("sup"))
                let fallback = "∫∬∭∮∯∰∱∲∳".contains(character) ? integralLimits : naryLimits
                let location = node.child("naryPr")?.child("limLoc").map { $0.attribute("val") ?? "undOvr" } ?? fallback
                guard ["subSup", "undOvr"].contains(location) else { throw WordImages.Failure.unsupported }
                let tag = location == "subSup" ? "msubsup" : "munderover"
                return "<mrow><\(tag)><mo largeop=\"true\" movablelimits=\"false\">\(MathMarkup.escape(character))</mo>\(lower)\(upper)</\(tag)>\(try child("e"))</mrow>"
            case "func": return "<mrow>\(try child("fName"))<mo>⁡</mo>\(try child("e"))</mrow>"
            case "limLow": return "<munder>\(try child("e"))\(try child("lim"))</munder>"
            case "limUpp": return "<mover>\(try child("e"))\(try child("lim"))</mover>"
            case "acc": return "<mover accent=\"true\">\(try child("e"))<mo>\(MathMarkup.escape(property("accPr", "chr", "̂")))</mo></mover>"
            case "bar": return property("barPr", "pos", "top") == "bot" ? "<munder>\(try child("e"))<mo>_</mo></munder>" : "<mover>\(try child("e"))<mo>¯</mo></mover>"
            case "m": return "<mtable>" + (try node.children.filter { $0.local == "mr" }.map { "<mtr>" + (try $0.children.filter { $0.local == "e" }.map { "<mtd>" + (try render($0)) + "</mtd>" }.joined()) + "</mtr>" }.joined()) + "</mtable>"
            case "eqArr": return "<mtable columnalign=\"left\">" + (try node.children.filter { $0.local == "e" }.map { "<mtr><mtd>" + (try render($0)) + "</mtd></mtr>" }.joined()) + "</mtable>"
            default: if node.local.hasSuffix("Pr") { return "" }; throw WordImages.Failure.feature("Unsupported Word equation structure: \(node.local).")
            }
        }
    }
}
