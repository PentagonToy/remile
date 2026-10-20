import Foundation

/// Local TeX notation to native MathML; deliberately no scripting or remote typesetter.
enum MathMarkup {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func render(_ source: String, display: Bool) throws -> String {
        guard source.utf8.count <= 100_000, source.components(separatedBy: "\\begin").count <= 65 else { throw Failure.syntax }
        var parser = Parser(source, display: display)
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
    private struct Node { var xml: String; var limits = false }
    private struct Parser {
        let characters: [Character]
        let display: Bool
        var position = 0
        var depth = 0
        init(_ text: String, display: Bool) { characters = Array(text); self.display = display }
        mutating func spaces() { while position < characters.count && characters[position].isWhitespace { position += 1 } }
        mutating func expression(until end: Character? = nil) throws -> String {
            guard depth < 128 else { throw Failure.syntax }
            depth += 1; defer { depth -= 1 }
            var result = ""
            while position < characters.count {
                spaces()
                if position == characters.count { break }
                if let end, characters[position] == end { position += 1; return result }
                guard characters[position] != "}" else { throw Failure.syntax }
                var base = try atom()
                var lower: String?, upper: String?
                while position < characters.count {
                    spaces()
                    if has("\\limits") { position += 7; base.limits = true; continue }
                    if has("\\nolimits") { position += 9; base.limits = false; continue }
                    guard position < characters.count, characters[position] == "_" || characters[position] == "^" else { break }
                    let kind = characters[position]; position += 1
                    let argument = try atom(single: true).xml
                    if kind == "_" { guard lower == nil else { throw Failure.syntax }; lower = argument }
                    else { guard upper == nil else { throw Failure.syntax }; upper = argument }
                }
                let limits = base.limits && display
                if let lower, let upper { base.xml = "<\(limits ? "munderover" : "msubsup")>\(base.xml)\(lower)\(upper)</\(limits ? "munderover" : "msubsup")>" }
                else if let lower { base.xml = "<\(limits ? "munder" : "msub")>\(base.xml)\(lower)</\(limits ? "munder" : "msub")>" }
                else if let upper { base.xml = "<\(limits ? "mover" : "msup")>\(base.xml)\(upper)</\(limits ? "mover" : "msup")>" }
                result += base.xml
            }
            if end != nil { throw Failure.syntax }
            return result
        }
        func has(_ string: String) -> Bool { characters[position...].starts(with: Array(string)) }
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
            spaces(); guard position < characters.count else { throw Failure.syntax }
            let character = characters[position]; position += 1
            if character == "{" { return Node(xml: "<mrow>\(try expression(until: "}"))</mrow>") }
            if character == "\\" { return try command() }
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
            if let value = Self.symbols[name] { return Node(xml: "<\(value.1)>\(escape(value.0))</\(value.1)>", limits: ["sum", "prod", "lim", "bigcup", "bigcap"].contains(name)) }
            switch name {
            case "frac", "dfrac", "tfrac": return Node(xml: "<mfrac>\(try atom(single: true).xml)\(try atom(single: true).xml)</mfrac>")
            case "binom": return Node(xml: "<mrow><mo>(</mo><mfrac linethickness=\"0\">\(try atom().xml)\(try atom().xml)</mfrac><mo>)</mo></mrow>")
            case "sqrt":
                spaces()
                if position < characters.count, characters[position] == "[" {
                    position += 1; let degree = try expression(until: "]")
                    return Node(xml: "<mroot>\(try atom().xml)<mrow>\(degree)</mrow></mroot>")
                }
                return Node(xml: "<msqrt>\(try atom().xml)</msqrt>")
            case "text", "textrm", "operatorname": return Node(xml: "<mtext>\(escape(try rawGroup()))</mtext>")
            case "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "mathscr", "mathsf", "mathtt", "boldsymbol":
                let variant = ["mathrm": "normal", "mathbf": "bold", "mathit": "italic", "mathbb": "double-struck", "mathcal": "script", "mathscr": "script", "mathsf": "sans-serif", "mathtt": "monospace", "boldsymbol": "bold-italic"][name]!
                return Node(xml: "<mstyle mathvariant=\"\(variant)\">\(try atom().xml)</mstyle>")
            case "hat", "widehat", "bar", "overline", "vec", "tilde", "widetilde", "dot", "ddot":
                let mark = ["hat": "^", "widehat": "^", "bar": "¯", "overline": "¯", "vec": "→", "tilde": "~", "widetilde": "~", "dot": "˙", "ddot": "¨"][name]!
                return Node(xml: "<mover accent=\"true\">\(try atom().xml)<mo>\(mark)</mo></mover>")
            case "underline": return Node(xml: "<munder accentunder=\"true\">\(try atom().xml)<mo>¯</mo></munder>")
            case "left", "right", "big", "Big", "bigg", "Bigg":
                spaces(); if position < characters.count && characters[position] == "." { position += 1; return Node(xml: "<mrow/>") }
                return try atom()
            case ",", ":", ";", " ", "quad", "qquad": return Node(xml: "<mspace width=\"\(name == "qquad" ? "2em" : name == "quad" ? "1em" : "0.2em")\"/>")
            case "!": return Node(xml: "<mspace width=\"-0.15em\"/>")
            case "begin": return try matrix(name: rawGroup())
            default: throw Failure.command(name)
            }
        }
        mutating func matrix(name: String) throws -> Node {
            let names = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "aligned", "align", "cases", "gathered", "smallmatrix"]
            guard names.contains(name) else { throw Failure.command("begin{\(name)}") }
            let closing = Array("\\end{\(name)}")
            let start = position
            var depth = 0
            while position < characters.count {
                if has("\\begin{\(name)}") { depth += 1 }
                if characters[position...].starts(with: closing) {
                    if depth == 0 { break }; depth -= 1
                }
                position += 1
            }
            guard position < characters.count else { throw Failure.syntax }
            let source = String(characters[start..<position]); position += closing.count
            let rows = split(source, separator: "\\\\")
            let aligned = ["align", "aligned"].contains(name)
            var table = aligned ? "<mtable columnalign=\"right left\" columnspacing=\"0em\" rowspacing=\"0.3em\">" : "<mtable>"
            for row in rows where !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                table += "<mtr>"
                for (column, cell) in split(row, separator: "&").enumerated() {
                    var parser = Parser(cell, display: display)
                    let alignment = aligned ? " style=\"text-align:\(column.isMultiple(of: 2) ? "right" : "left")\"" : ""
                    table += "<mtd\(alignment)><mrow>\(try parser.expression())</mrow></mtd>"
                }
                table += "</mtr>"
            }
            table += "</mtable>"
            let fences: [String: (String, String)] = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", "")]
            if let fence = fences[name] { table = "<mrow><mo stretchy=\"true\">\(fence.0)</mo>\(table)<mo stretchy=\"true\">\(fence.1)</mo></mrow>" }
            return Node(xml: table)
        }
        func split(_ text: String, separator: String) -> [String] {
            let chars = Array(text), delimiter = Array(separator)
            var parts: [String] = [], start = 0, index = 0, depth = 0
            while index < chars.count {
                if depth == 0 && chars[index...].starts(with: delimiter) { parts.append(String(chars[start..<index])); index += delimiter.count; start = index; continue }
                if chars[index] == "{" { depth += 1 }
                if chars[index] == "}" { depth -= 1 }
                index += 1
            }
            parts.append(String(chars[start...])); return parts
        }
        static let symbols: [String: (String, String)] = {
            var map: [String: (String, String)] = [:]
            let greek = ["alpha":"α","beta":"β","gamma":"γ","delta":"δ","epsilon":"ϵ","varepsilon":"ε","zeta":"ζ","eta":"η","theta":"θ","vartheta":"ϑ","iota":"ι","kappa":"κ","lambda":"λ","mu":"μ","nu":"ν","xi":"ξ","pi":"π","varpi":"ϖ","rho":"ρ","varrho":"ϱ","sigma":"σ","varsigma":"ς","tau":"τ","upsilon":"υ","phi":"ϕ","varphi":"φ","chi":"χ","psi":"ψ","omega":"ω","Gamma":"Γ","Delta":"Δ","Theta":"Θ","Lambda":"Λ","Xi":"Ξ","Pi":"Π","Sigma":"Σ","Upsilon":"Υ","Phi":"Φ","Psi":"Ψ","Omega":"Ω"]
            for (key, value) in greek { map[key] = (value, "mi") }
            let operators = ["sum":"∑","prod":"∏","int":"∫","iint":"∬","iiint":"∭","oint":"∮","partial":"∂","nabla":"∇","infty":"∞","cdot":"⋅","times":"×","div":"÷","pm":"±","mp":"∓","le":"≤","leq":"≤","ge":"≥","geq":"≥","ne":"≠","neq":"≠","approx":"≈","equiv":"≡","sim":"∼","simeq":"≃","propto":"∝","to":"→","rightarrow":"→","leftarrow":"←","leftrightarrow":"↔","Rightarrow":"⇒","Leftarrow":"⇐","Leftrightarrow":"⇔","in":"∈","notin":"∉","subset":"⊂","subseteq":"⊆","supset":"⊃","supseteq":"⊇","cup":"∪","cap":"∩","bigcup":"⋃","bigcap":"⋂","forall":"∀","exists":"∃","neg":"¬","land":"∧","lor":"∨","ldots":"…","cdots":"⋯","vdots":"⋮","ddots":"⋱","langle":"⟨","rangle":"⟩","lvert":"|","rvert":"|","lVert":"‖","rVert":"‖","{":"{","}":"}","%":"%","$":"$","_":"_","#":"#","&":"&","backslash":"\\","emptyset":"∅","perp":"⊥","parallel":"∥","otimes":"⊗","oplus":"⊕"]
            for (key, value) in operators { map[key] = (value, "mo") }
            for name in ["sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "log", "ln", "exp", "lim", "max", "min", "sup", "inf", "det", "gcd"] { map[name] = (name, "mi") }
            return map
        }()
    }
}
