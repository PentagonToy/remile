import Foundation

/// Display-only fallback. Source text, citations and copied LaTeX remain untouched.
enum ReadableMath {
    static func display(_ source: String) -> String {
        var fence: Character?, fenceLength = 0
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                if length >= 3 {
                    if fence == nil { fence = marker; fenceLength = length }
                    else if fence == marker && length >= fenceLength && trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    return line
                }
            }
            guard fence == nil else { return line }
            guard let regex = try? NSRegularExpression(pattern: #"(`+).*?\1"#) else { return convert(line) }
            let raw = line as NSString
            var result = "", start = 0
            for match in regex.matches(in: line, range: NSRange(location: 0, length: raw.length)) {
                result += convert(raw.substring(with: NSRange(location: start, length: match.range.location - start)))
                result += raw.substring(with: match.range); start = NSMaxRange(match.range)
            }
            return result + convert(raw.substring(from: start))
        }.joined(separator: "\n")
    }
    private static func convert(_ source: String) -> String {
        var text = source
        let symbols = ["epsilon":"ε", "varepsilon":"ε", "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "theta":"θ", "lambda":"λ", "mu":"μ", "nu":"ν", "rho":"ρ", "sigma":"σ", "tau":"τ", "phi":"φ", "omega":"ω", "pi":"π", "partial":"∂", "nabla":"∇", "times":"×", "cdot":"·", "leq":"≤", "geq":"≥", "approx":"≈", "infty":"∞", "sum":"∑", "int":"∫"]
        for (command, value) in symbols { text = text.replacingOccurrences(of: "\\\\" + command + "(?![A-Za-z])", with: value, options: .regularExpression) }
        for _ in 0..<3 { text = text.replacingOccurrences(of: "\\\\(?:mathrm|text|operatorname)\\{([^{}]*)\\}", with: "$1", options: .regularExpression) }
        text = text.replacingOccurrences(of: "\\\\frac\\{([^{}]+)\\}\\{([^{}]+)\\}", with: "($1)/($2)", options: .regularExpression)
        for pattern in [#"\\\((.+?)\\\)"#, #"\\\[(.+?)\\\]"#] {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        // A dollar amount is prose. Only remove paired delimiters around formula-like content.
        if let regex = try? NSRegularExpression(pattern: #"(?<![\\$])\${1,2}([^$\n]+)\${1,2}(?!\$)"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let body = (text as NSString).substring(with: match.range(at: 1))
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                let expression = body.rangeOfCharacter(from: CharacterSet(charactersIn: "=^_+×∑∫")) != nil
                if trimmed.first?.isNumber != true && (expression || trimmed.first?.isLetter == true) {
                    text = (text as NSString).replacingCharacters(in: match.range, with: body)
                }
            }
        }
        text = text.replacingOccurrences(of: "(?<![A-Za-z])k\\s*[-–−]\\s*ε", with: "k–ε", options: .regularExpression)
        return text
    }
}
