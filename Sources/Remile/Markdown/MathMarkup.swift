import Foundation

/// Local TeX notation to native MathML; deliberately no scripting or remote typesetter.
enum MathMarkup {
    static func completionPreview(_ command: String) -> String? {
        guard command.first == "\\" else { return nil }
        switch command {
        case "\\frac{}{}": return "a⁄b"
        case "\\sqrt{}": return "√x"
        default: return Parser.symbols[String(command.dropFirst())]?.0
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func render(_ source: String, display: Bool, highlightOffset: Int? = nil) throws -> String {
        guard source.utf8.count <= 100_000, source.components(separatedBy: "\\begin").count <= 65 else { throw Failure.syntax }
        var parser = Parser(source, display: display, highlightOffset: highlightOffset)
        let body = try parser.expression()
        guard parser.position == parser.characters.count else { throw Failure.syntax }
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display ? "block" : "inline")\"><mrow>\(body)</mrow></math>"
    }
    enum Failure: LocalizedError {
        case syntax, command(String)
        var errorDescription: String? {
            switch self {
            case .syntax: return "Invalid formula."
            case .command(let name): return "Unsupported formula command: \\\(name)"
            }
        }
    }
    private enum Style: String {
        case displaystyle, textstyle, scriptstyle, scriptscriptstyle

        var openingTag: String {
            let level = self == .scriptstyle ? 1 : self == .scriptscriptstyle ? 2 : 0
            return "<mstyle displaystyle=\"\(self == .displaystyle)\" scriptlevel=\"\(level)\">"
        }
    }

    private struct Node {
        var xml: String
        var limits = false
        var braceAnnotation = false
        var style: Style? = nil
    }
    private struct Parser {
        let characters: [Character]
        var display: Bool
        let highlightOffset: Int?
        var position = 0
        var depth = 0
        init(_ text: String, display: Bool, highlightOffset: Int? = nil) {
            characters = Array(text); self.display = display; self.highlightOffset = highlightOffset
        }
        mutating func spaces() { while position < characters.count && characters[position].isWhitespace { position += 1 } }
        mutating func expression(until end: Character? = nil) throws -> String {
            let originalDisplay = display
            defer { display = originalDisplay }
            var style: Style?
            var closed = end == nil
            var result = ""
            while position < characters.count {
                spaces()
                if position == characters.count { break }
                if let end, characters[position] == end {
                    position += 1
                    closed = true
                    break
                }
                guard characters[position] != "}" else { throw Failure.syntax }
                var base = try atom()
                if let nextStyle = base.style {
                    if style != nil { result += "</mstyle>" }
                    result += nextStyle.openingTag
                    style = nextStyle
                    display = nextStyle == .displaystyle
                    continue
                }
                var lower: String?, upper: String?
                var explicitLimits: Bool?
                while position < characters.count {
                    spaces()
                    if position < characters.count, characters[position] == "\\" {
                        if consumeControlWord("\\limits") { explicitLimits = true; continue }
                        if consumeControlWord("\\nolimits") { explicitLimits = false; continue }
                        if consumeControlWord("\\displaylimits") { explicitLimits = display; continue }
                    }
                    guard position < characters.count, characters[position] == "_" || characters[position] == "^" else { break }
                    let kind = characters[position]; position += 1
                    let argument = try atom(single: true).xml
                    if kind == "_" { guard lower == nil else { throw Failure.syntax }; lower = argument }
                    else { guard upper == nil else { throw Failure.syntax }; upper = argument }
                }
                let limits = explicitLimits ?? (base.braceAnnotation || (base.limits && display))
                if let lower, let upper { base.xml = "<\(limits ? "munderover" : "msubsup")>\(base.xml)\(lower)\(upper)</\(limits ? "munderover" : "msubsup")>" }
                else if let lower { base.xml = "<\(limits ? "munder" : "msub")>\(base.xml)\(lower)</\(limits ? "munder" : "msub")>" }
                else if let upper { base.xml = "<\(limits ? "mover" : "msup")>\(base.xml)\(upper)</\(limits ? "mover" : "msup")>" }
                result += base.xml
            }
            guard closed else { throw Failure.syntax }
            if style != nil { result += "</mstyle>" }
            return result
        }
        func has(_ string: String) -> Bool { characters[position...].starts(with: string) }
        mutating func consumeControlWord(_ word: String) -> Bool {
            guard has(word) else { return false }
            let next = position + word.count
            guard next == characters.count || !characters[next].isLetter else { return false }
            position = next
            return true
        }
        mutating func rawGroup() throws -> String {
            spaces(); guard position < characters.count, characters[position] == "{" else { throw Failure.syntax }
            position += 1; let start = position; var depth = 1
            while position < characters.count {
                if characters[position] == "\\" { position += 2; continue }
                if characters[position] == "{" { depth += 1 }
                if characters[position] == "}" { depth -= 1; if depth == 0 { let text = String(characters[start..<position]); position += 1; return text } }
                position += 1
            }
            throw Failure.syntax
        }
        mutating func atom(single: Bool = false) throws -> Node {
            guard depth < 128 else { throw Failure.syntax }
            depth += 1; defer { depth -= 1 }
            spaces(); guard position < characters.count else { throw Failure.syntax }
            let character = characters[position]; position += 1
            if character == "{" { return Node(xml: "<mrow>\(try expression(until: "}"))</mrow>") }
            if character == "\\" {
                let node = try command()
                if single, node.style != nil { throw Failure.syntax }
                return node
            }
            guard character != "}" && character != "^" && character != "_" else { throw Failure.syntax }
            if character.isNumber {
                var number = String(character)
                while !single && position < characters.count && (characters[position].isNumber || characters[position] == ".") { number.append(characters[position]); position += 1 }
                return Node(xml: "<mn>\(escape(number))</mn>")
            }
            let tag = character.isLetter ? "mi" : "mo"
            return Node(xml: "<\(tag)>\(escape(String(character)))</\(tag)>")
        }
        mutating func command() throws -> Node {
            guard position < characters.count else { throw Failure.syntax }
            let start = position
            if characters[position].isLetter { while position < characters.count && characters[position].isLetter { position += 1 } }
            else { position += 1 }
            let name = String(characters[start..<position])
            if let style = Style(rawValue: name) { return Node(xml: "", style: style) }
            if let arrow = Self.annotatedArrows[name] { return try annotatedArrow(arrow) }
            if let value = Self.symbols[name] {
                return Node(xml: "<\(value.1)>\(escape(value.0))</\(value.1)>", limits: Self.limitOperators.contains(name))
            }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let outerDisplay = display
                defer { display = outerDisplay }
                // shortcut: centred continued fractions, extend when the preview can align their numerators
                if name == "cfrac" {
                    spaces()
                    guard !has("[") else { throw Failure.command(name) }
                    display = true
                }
                let fraction = "<mfrac>\(try atom(single: true).xml)\(try atom(single: true).xml)</mfrac>"
                switch name {
                case "frac": return Node(xml: fraction)
                case "cfrac": return Node(xml: Style.displaystyle.openingTag + fraction + "</mstyle>")
                default: return Node(xml: "<mstyle displaystyle=\"\(name == "dfrac")\">\(fraction)</mstyle>")
                }
            case "boxed":
                return Node(xml: "<mrow style=\"border:1px solid currentColor;padding:0.15em\">\(try atom(single: true).xml)</mrow>")
            case "cancel", "bcancel", "xcancel":
                let notation = Self.strikeNotations[name]!
                return Node(xml: "<menclose notation=\"\(notation)\">\(try atom(single: true).xml)</menclose>")
            case "binom", "dbinom", "tbinom":
                return Node(xml: "<mrow><mo>(</mo><mfrac linethickness=\"0\">\(try atom(single: true).xml)\(try atom(single: true).xml)</mfrac><mo>)</mo></mrow>")
            case "overset", "stackrel", "underset":
                let annotation = try atom(single: true).xml
                let base = try atom(single: true).xml
                let tag = name == "underset" ? "munder" : "mover"
                return Node(xml: "<\(tag)>\(base)\(annotation)</\(tag)>")
            case "overbrace", "underbrace":
                let over = name == "overbrace"
                let tag = over ? "mover" : "munder"
                let accent = over ? "accent" : "accentunder"
                let brace = over ? "⏞" : "⏟"
                return Node(xml: "<\(tag) \(accent)=\"true\">\(try atom(single: true).xml)<mo stretchy=\"true\">\(brace)</mo></\(tag)>",
                            braceAnnotation: true)
            case "substack":
                return try table(rawGroup(), aligned: false, start: position, stack: true)
            case "phantom":
                return Node(xml: "<mphantom>\(try atom(single: true).xml)</mphantom>")
            case "hphantom":
                return Node(xml: "<mpadded height=\"0\" depth=\"0\"><mphantom>\(try atom(single: true).xml)</mphantom></mpadded>")
            case "vphantom", "mathstrut":
                let content = name == "mathstrut" ? "<mo>(</mo>" : try atom(single: true).xml
                return Node(xml: "<mpadded width=\"0\"><mphantom>\(content)</mphantom></mpadded>")
            case "smash":
                spaces()
                let topOnly = has("[t]")
                let bottomOnly = has("[b]")
                if topOnly || bottomOnly { position += 3 }
                else if has("[tb]") { position += 4 }
                else if has("[") { throw Failure.command(name) }
                let height = bottomOnly ? "" : #" height="0""#
                let depth = topOnly ? "" : #" depth="0""#
                return Node(xml: "<mpadded\(height)\(depth)>\(try atom(single: true).xml)</mpadded>")
            case "sqrt":
                spaces()
                if position < characters.count, characters[position] == "[" {
                    position += 1; let degree = try expression(until: "]")
                    return Node(xml: "<mroot>\(try atom(single: true).xml)<mrow>\(degree)</mrow></mroot>")
                }
                return Node(xml: "<msqrt>\(try atom(single: true).xml)</msqrt>")
            case "tag":
                spaces()
                let bare = has("*")
                if bare { position += 1 }
                let label = escape(try rawGroup())
                return Node(xml: "<mspace width=\"1em\"/><mtext>\(bare ? label : "(\(label))")</mtext>")
            case "text", "textrm", "textnormal", "textup", "mbox":
                return Node(xml: "<mtext>\(escape(try textGroup()))</mtext>")
            case "textbf", "textit", "textsf", "texttt":
                let style = Self.textStyles[name]!
                return Node(xml: "<mtext style=\"\(style)\">\(escape(try textGroup()))</mtext>")
            case "operatorname":
                let hasLimits = has("*")
                if hasLimits { position += 1 }
                let text = try rawGroup().replacingOccurrences(of: #"\,"#, with: " ")
                return Node(xml: "<mo>\(escape(text))</mo>", limits: hasLimits)
            case "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "mathscr", "mathsf", "mathtt", "mathfrak", "boldsymbol", "bm":
                let variant = ["mathrm": "normal", "mathbf": "bold", "mathit": "italic", "mathbb": "double-struck", "mathcal": "script", "mathscr": "script", "mathsf": "sans-serif", "mathtt": "monospace", "mathfrak": "fraktur", "boldsymbol": "bold-italic", "bm": "bold-italic"][name]!
                return Node(xml: "<mstyle mathvariant=\"\(variant)\">\(try atom(single: true).xml)</mstyle>")
            case "hat", "widehat", "bar", "overline", "vec", "tilde", "widetilde", "dot", "ddot",
                 "dddot", "ddddot", "breve", "check", "acute", "grave", "mathring":
                let mark = Self.accents[name]!
                return Node(xml: "<mover accent=\"true\">\(try atom(single: true).xml)<mo>\(mark)</mo></mover>")
            case "underline": return Node(xml: "<munder accentunder=\"true\">\(try atom(single: true).xml)<mo>¯</mo></munder>")
            case "overrightarrow", "overleftarrow", "overleftrightarrow",
                 "underrightarrow", "underleftarrow", "underleftrightarrow":
                let under = name.hasPrefix("under")
                let tag = under ? "munder" : "mover"
                let accent = under ? "accentunder" : "accent"
                let arrow = name.hasSuffix("leftrightarrow") ? "↔" : name.hasSuffix("leftarrow") ? "←" : "→"
                return Node(xml: "<\(tag) \(accent)=\"true\">\(try atom(single: true).xml)<mo stretchy=\"true\">\(arrow)</mo></\(tag)>")
            case "bmod": return Node(xml: "<mo lspace=\"0.22em\" rspace=\"0.22em\">mod</mo>")
            case "not":
                let relation = try atom(single: true).xml
                guard let negated = Self.negatedRelations[relation] else { throw Failure.command(name) }
                return Node(xml: "<mo>\(negated)</mo>")
            case "mod", "pmod", "pod":
                let modulus = try atom(single: true).xml
                let label = "<mtext>mod</mtext><mspace width=\"0.33em\"/>"
                let body = name == "mod" ? label + modulus : "<mo>(</mo>\(name == "pmod" ? label : "")\(modulus)<mo>)</mo>"
                return Node(xml: "<mrow><mspace width=\"0.5em\"/>\(body)</mrow>")
            case "left", "right",
                 "big", "bigl", "bigm", "bigr", "Big", "Bigl", "Bigm", "Bigr",
                 "bigg", "biggl", "biggm", "biggr", "Bigg", "Biggl", "Biggm", "Biggr":
                spaces(); if position < characters.count && characters[position] == "." { position += 1; return Node(xml: "<mrow/>") }
                return try atom()
            case "middle":
                let delimiter = try atom(single: true).xml
                guard delimiter.hasPrefix("<mo>") else { throw Failure.syntax }
                return Node(xml: "<mo stretchy=\"true\">" + delimiter.dropFirst(4))
            case ",", ":", ";", " ", "quad", "qquad", "thinspace", "medspace", "thickspace", "enspace", "!":
                let width = Self.spaces[name] ?? "0.2em"
                return Node(xml: "<mspace width=\"\(width)\"/>")
            case "label":
                _ = try rawGroup()
                return Node(xml: "")
            case "notag", "nonumber": return Node(xml: "<mrow/>")
            case "begin": return try matrix(name: rawGroup())
            default: throw Failure.command(name)
            }
        }
        mutating func annotatedArrow(_ arrow: String) throws -> Node {
            spaces()
            let lower: String?
            if has("[") {
                position += 1
                lower = try expression(until: "]")
            } else {
                lower = nil
            }
            let upper = try atom(single: true).xml
            let base = "<mo stretchy=\"true\">\(arrow)</mo>"
            if let lower {
                return Node(xml: "<munderover>\(base)<mrow>\(lower)</mrow>\(upper)</munderover>")
            }
            return Node(xml: "<mover>\(base)\(upper)</mover>")
        }
        mutating func textGroup() throws -> String {
            let source = try rawGroup()
            guard source.contains("\\") else { return source }
            var text = ""
            var characters = source.makeIterator()
            while let character = characters.next() {
                if character == "\\", let next = characters.next() {
                    if !"#$%&_{}".contains(next) { text.append(character) }
                    text.append(next)
                } else {
                    text.append(character)
                }
            }
            return text
        }
        mutating func matrix(name: String) throws -> Node {
            let names = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "aligned", "align", "align*", "alignedat", "alignat", "alignat*", "split", "equation", "equation*", "gather", "gather*", "cases", "gathered", "smallmatrix", "array", "multline", "multline*"]
            guard names.contains(name) else { throw Failure.command("begin{\(name)}") }
            let usesColumnCount = ["alignedat", "alignat", "alignat*"].contains(name)
            if name == "alignedat" || name == "aligned" || name == "gathered" || name == "array" {
                spaces()
                if has("[t]") || has("[b]") || has("[c]") { position += 3 }
            }
            if usesColumnCount {
                let count = try rawGroup().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let columns = Int(count), columns > 0 else { throw Failure.syntax }
            }
            var columnAlignments: [String] = []
            if name == "array" {
                // shortcut: plain l/c/r columns, extend when the preview can represent TeX rules and custom column types
                let columns = try rawGroup().filter { !$0.isWhitespace }
                guard !columns.isEmpty, columns.allSatisfy({ Self.columnAlignment[$0] != nil }) else {
                    throw Failure.command("begin{array}")
                }
                columnAlignments = columns.compactMap { Self.columnAlignment[$0] }
            }
            let opening = Array("\\begin{\(name)}")
            let closing = Array("\\end{\(name)}")
            let start = position
            var depth = 0
            while position < characters.count {
                if characters[position...].starts(with: opening) { depth += 1 }
                if characters[position...].starts(with: closing) {
                    if depth == 0 { break }; depth -= 1
                }
                position += 1
            }
            guard position < characters.count else { throw Failure.syntax }
            let source = String(characters[start..<position]); position += closing.count
            let aligned = usesColumnCount || ["align", "align*", "aligned", "split"].contains(name)
            let multline = name == "multline" || name == "multline*"
            var result = try table(source, aligned: aligned, start: start, columnAlignments: columnAlignments, multline: multline)
            let fences: [String: (String, String)] = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", "")]
            if let fence = fences[name] {
                result.xml = "<mrow><mo stretchy=\"true\">\(fence.0)</mo>\(result.xml)<mo stretchy=\"true\">\(fence.1)</mo></mrow>"
            }
            return result
        }
        func table(_ source: String, aligned: Bool, start: Int, stack: Bool = false, columnAlignments: [String] = [],
                   multline: Bool = false) throws -> Node {
            let rows = split(source, separator: "\\\\")
            let lastRow = multline ? rows.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) : nil
            var firstRow = true
            var table = "<mtable>"
            if aligned {
                table = "<mtable columnalign=\"right left\" columnspacing=\"0em\" rowspacing=\"0.3em\">"
            } else if multline {
                table = "<mtable style=\"width:100%\">"
            }
            var rowStart = start
            for (index, row) in rows.enumerated() {
                let rowEnd = rowStart + row.count
                let active = aligned && highlightOffset.map { (rowStart...rowEnd).contains($0) } == true
                rowStart = rowEnd + 2
                guard !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                table += active ? "<mtr class=\"active-equation-row\">" : "<mtr>"
                let cells = stack ? [row] : split(row, separator: "&")
                guard !multline || cells.count == 1 else { throw Failure.syntax }
                guard columnAlignments.isEmpty || cells.count <= columnAlignments.count else { throw Failure.syntax }
                for (column, cell) in cells.enumerated() {
                    var parser = Parser(cell, display: display)
                    parser.depth = depth
                    let horizontalAlignment: String?
                    if multline {
                        if firstRow { horizontalAlignment = index == lastRow ? "center" : "left" }
                        else { horizontalAlignment = index == lastRow ? "right" : "center" }
                    } else if aligned { horizontalAlignment = column.isMultiple(of: 2) ? "right" : "left" }
                    else { horizontalAlignment = columnAlignments.isEmpty ? nil : columnAlignments[column] }
                    let alignment = horizontalAlignment.map { " style=\"text-align:\($0)\"" } ?? ""
                    table += "<mtd\(alignment)><mrow>\(try parser.expression())</mrow></mtd>"
                }
                firstRow = false
                table += "</mtr>"
            }
            table += "</mtable>"
            return Node(xml: stack ? "<mstyle scriptlevel=\"1\">\(table)</mstyle>" : table)
        }
        func split(_ text: String, separator: String) -> [String] {
            let chars = Array(text), delimiter = Array(separator)
            let begin = Array("\\begin{"), end = Array("\\end{")
            var parts: [String] = [], start = 0, index = 0, depth = 0, environments = 0
            while index < chars.count {
                if depth == 0 && environments == 0 && chars[index...].starts(with: delimiter) {
                    parts.append(String(chars[start..<index])); index += delimiter.count; start = index; continue
                }
                if chars[index] == "\\" {
                    if chars[index...].starts(with: begin) { environments += 1 }
                    if chars[index...].starts(with: end) { environments -= 1 }
                    index += 2
                    continue
                }
                if chars[index] == "{" { depth += 1 }
                if chars[index] == "}" { depth -= 1 }
                index += 1
            }
            parts.append(String(chars[start...])); return parts
        }
        static let limitOperators: Set<String> = [
            "sum", "prod", "coprod", "lim", "liminf", "limsup", "max", "min", "sup", "inf",
            "bigcup", "bigcap", "bigvee", "bigwedge", "bigoplus", "bigotimes", "bigodot", "biguplus", "bigsqcup",
        ]
        static let annotatedArrows = [
            "xleftarrow": "←", "xrightarrow": "→", "xleftrightarrow": "↔", "xmapsto": "↦",
            "xLeftarrow": "⇐", "xRightarrow": "⇒", "xLeftrightarrow": "⇔",
            "xhookleftarrow": "↩", "xhookrightarrow": "↪", "xrightleftharpoons": "⇌",
        ]
        static let spaces = [
            "quad": "1em", "qquad": "2em", "enspace": "0.5em",
            "thinspace": "0.167em", "medspace": "0.222em", "thickspace": "0.278em", "!": "-0.15em",
        ]
        static let columnAlignment: [Character: String] = ["l": "left", "c": "center", "r": "right"]
        static let negatedRelations: [String: String] = [
            "=": "≠", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱", "≡": "≢",
            "∼": "≁", "≈": "≉", "≅": "≇", "∈": "∉", "∋": "∌",
            "⊂": "⊄", "⊃": "⊅", "⊆": "⊈", "⊇": "⊉", "∣": "∤", "∥": "∦",
        ].reduce(into: [:]) { result, pair in
            result["<mo>\(escape(pair.key))</mo>"] = pair.value
        }
        static let strikeNotations = [
            "cancel": "updiagonalstrike", "bcancel": "downdiagonalstrike", "xcancel": "updiagonalstrike downdiagonalstrike",
        ]
        static let textStyles = [
            "textbf": "font-weight:bold", "textit": "font-style:italic",
            "textsf": "font-family:sans-serif", "texttt": "font-family:monospace",
        ]
        static let accents = [
            "hat": "^", "widehat": "^", "bar": "¯", "overline": "¯", "vec": "→", "tilde": "~",
            "widetilde": "~", "dot": "˙", "ddot": "¨", "dddot": "⃛", "ddddot": "⃜",
            "breve": "˘", "check": "ˇ", "acute": "´", "grave": "`", "mathring": "˚",
        ]
        static let symbols: [String: (String, String)] = {
            var map: [String: (String, String)] = [:]
            let greek = ["alpha":"α","beta":"β","gamma":"γ","delta":"δ","epsilon":"ϵ","varepsilon":"ε","zeta":"ζ","eta":"η","theta":"θ","vartheta":"ϑ","iota":"ι","kappa":"κ","lambda":"λ","mu":"μ","nu":"ν","xi":"ξ","pi":"π","varpi":"ϖ","rho":"ρ","varrho":"ϱ","sigma":"σ","varsigma":"ς","tau":"τ","upsilon":"υ","phi":"ϕ","varphi":"φ","chi":"χ","psi":"ψ","omega":"ω","Gamma":"Γ","Delta":"Δ","Theta":"Θ","Lambda":"Λ","Xi":"Ξ","Pi":"Π","Sigma":"Σ","Upsilon":"Υ","Phi":"Φ","Psi":"Ψ","Omega":"Ω"]
            for (key, value) in greek { map[key] = (value, "mi") }
            let operators = ["sum":"∑","prod":"∏","int":"∫","iint":"∬","iiint":"∭","oint":"∮","partial":"∂","nabla":"∇","infty":"∞","cdot":"⋅","times":"×","div":"÷","pm":"±","mp":"∓","le":"≤","leq":"≤","ge":"≥","geq":"≥","ne":"≠","neq":"≠","approx":"≈","equiv":"≡","sim":"∼","simeq":"≃","propto":"∝","to":"→","rightarrow":"→","leftarrow":"←","uparrow":"↑","downarrow":"↓","leftrightarrow":"↔","Rightarrow":"⇒","Leftarrow":"⇐","Leftrightarrow":"⇔","in":"∈","notin":"∉","subset":"⊂","subseteq":"⊆","supset":"⊃","supseteq":"⊇","cup":"∪","cap":"∩","bigcup":"⋃","bigcap":"⋂","forall":"∀","exists":"∃","neg":"¬","land":"∧","lor":"∨","ldots":"…","cdots":"⋯","vdots":"⋮","ddots":"⋱","langle":"⟨","rangle":"⟩","lvert":"|","rvert":"|","lVert":"‖","rVert":"‖","{":"{","}":"}","%":"%","$":"$","_":"_","#":"#","&":"&","backslash":"\\","emptyset":"∅","perp":"⊥","parallel":"∥","otimes":"⊗","oplus":"⊕","prime":"′","circ":"∘","ll":"≪","mid":"∣","|":"‖"]
            for (key, value) in operators { map[key] = (value, "mo") }
            let additionalOperators = [
                "mapsto": "↦", "longmapsto": "⟼", "longrightarrow": "⟶", "longleftarrow": "⟵",
                "longleftrightarrow": "⟷", "Longrightarrow": "⟹", "Longleftarrow": "⟸",
                "Longleftrightarrow": "⟺", "implies": "⟹", "impliedby": "⟸", "iff": "⟺",
                "hookrightarrow": "↪", "hookleftarrow": "↩",
                "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓", "Updownarrow": "⇕",
                "dots": "…", "dotsc": "…", "dotso": "…", "dotsb": "⋯", "dotsm": "⋯", "dotsi": "⋯",
                "gg": "≫", "lesssim": "≲", "gtrsim": "≳", "cong": "≅", "asymp": "≍",
                "leqslant": "⩽", "geqslant": "⩾", "subsetneq": "⊊", "supsetneq": "⊋",
                "ni": "∋", "setminus": "∖", "varnothing": "∅", "therefore": "∴", "because": "∵",
                "coloneqq": "≔", "eqqcolon": "≕", "triangleq": "≜", "doteq": "≐", "colon": ":",
                "bullet": "∙", "ast": "∗", "star": "⋆", "degree": "°", "top": "⊤", "bot": "⊥",
                "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "vert": "|", "Vert": "‖",
                "coprod": "∐", "bigvee": "⋁", "bigwedge": "⋀", "bigoplus": "⨁", "bigotimes": "⨂",
                "nexists": "∄", "nsubseteq": "⊈", "nsupseteq": "⊉", "nparallel": "∦", "nmid": "∤",
                "nrightarrow": "↛", "nleftarrow": "↚", "nleftrightarrow": "↮",
                "nRightarrow": "⇏", "nLeftarrow": "⇍", "nLeftrightarrow": "⇎",
                "nless": "≮", "ngtr": "≯", "nleq": "≰", "ngeq": "≱", "ncong": "≇", "nsim": "≁",
                "lt": "<", "gt": ">",
                "iiiint": "⨌", "oiint": "∯", "oiiint": "∰", "smallsetminus": "∖",
                "triangleleft": "◃", "triangleright": "▹", "trianglelefteq": "⊴", "trianglerighteq": "⊵",
                "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "sqcup": "⊔", "sqcap": "⊓",
                "gets": "←", "leadsto": "⇝", "rightleftharpoons": "⇌", "leftrightharpoons": "⇋",
                "lnot": "¬", "wedge": "∧", "vee": "∨", "vdash": "⊢", "dashv": "⊣", "models": "⊨",
                "complement": "∁", "subseteqq": "⫅", "supseteqq": "⫆", "nsubset": "⊄", "nsupset": "⊅",
                "uplus": "⊎", "biguplus": "⨄", "bigsqcup": "⨆", "odot": "⊙", "bigodot": "⨀", "oslash": "⊘",
                "llbracket": "⟦", "rrbracket": "⟧", "measuredangle": "∡", "angle": "∠",
                "leftharpoonup": "↼", "leftharpoondown": "↽", "rightharpoonup": "⇀", "rightharpoondown": "⇁",
                "leftrightarrows": "⇆", "rightleftarrows": "⇄", "twoheadrightarrow": "↠", "twoheadleftarrow": "↞",
                "multimap": "⊸", "sphericalangle": "∢",
                "npreceq": "⋠", "nsucceq": "⋡", "approxeq": "≊", "fallingdotseq": "≒", "risingdotseq": "≓",
                "boxplus": "⊞", "boxminus": "⊟", "boxtimes": "⊠", "boxdot": "⊡",
            ]
            for (key, value) in additionalOperators { map[key] = (value, "mo") }
            let identifiers = ["ell": "ℓ", "hbar": "ℏ", "hslash": "ℏ", "Re": "ℜ", "Im": "ℑ",
                               "aleph": "ℵ", "beth": "ℶ", "wp": "℘", "varTheta": "ϴ", "varkappa": "ϰ",
                               "digamma": "ϝ", "imath": "ı", "jmath": "ȷ"]
            for (key, value) in identifiers { map[key] = (value, "mi") }
            for (key, value) in ["liminf": "lim inf", "limsup": "lim sup", "arg": "arg", "dim": "dim",
                                 "ker": "ker", "deg": "deg", "hom": "hom", "Pr": "Pr"] {
                map[key] = (value, "mi")
            }
            for name in ["sin", "cos", "tan", "arccos", "arcsin", "arctan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "log", "ln", "exp", "lim", "max", "min", "sup", "inf", "det", "gcd"] { map[name] = (name, "mi") }
            return map
        }()
    }
}
