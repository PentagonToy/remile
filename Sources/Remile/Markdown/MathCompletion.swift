import Foundation

/// Explicit, local TeX completion. Source offsets use the editor's UTF-16 coordinates.
enum MathCompletion {
    struct Context { let range: NSRange; let prefix: String }
    static let commands = [
        "alpha", "beta", "gamma", "eta", "kappa", "xi", "upsilon", "chi", "psi", "zeta", "delta", "epsilon", "varepsilon", "theta", "lambda", "mu", "nu", "pi", "rho", "sigma", "tau", "phi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Sigma", "Phi", "Omega", "partial", "nabla", "infty", "cdot", "times", "leq", "geq", "neq", "approx", "sum", "prod", "int", "lim",
        "sin", "cos", "tan", "log", "ln", "exp", "min", "max", "sup", "inf", "det", "forall", "exists", "in", "notin", "subset", "subseteq", "cup", "cap", "rightarrow", "leftarrow", "Rightarrow", "leftrightarrow", "overline{}", "underline{}", "underbrace{}", "overbrace{}", "mathbb{}", "mathcal{}", "mathsf{}", "operatorname{}", "boldsymbol{}", "frac{}{}", "sqrt{}", "text{}", "mathrm{}", "mathbf{}", "hat{}", "bar{}", "vec{}"
    ].map { "\\" + $0 }.sorted()

    static func context(_ source: String, selection: NSRange) -> Context? {
        let value = source as NSString
        // Explicit invocation remains bounded even for an unusually large source document.
        guard selection.length == 0, selection.location > 0, selection.location <= value.length, selection.location <= 200_000 else { return nil }
        if selection.location < value.length, letter(value.character(at: selection.location)) || value.character(at: selection.location) == 123 { return nil }
        let units = Array(value.substring(to: selection.location).utf16)
        var start = units.count
        while start > 0, letter(units[start - 1]) { start -= 1 }
        guard start > 0, units[start - 1] == 92 else { return nil }
        start -= 1
        // A command after an escaped backslash is not a command to replace.
        var slash = start
        while slash > 0, units[slash - 1] == 92 { slash -= 1 }
        guard (start - slash).isMultiple(of: 2), insideMath(Array(units[...start])) else { return nil }
        let range = NSRange(location: start, length: units.count - start)
        return Context(range: range, prefix: value.substring(with: range))
    }

    static func suggestions(_ context: Context) -> [String] {
        Array(commands.filter { $0.hasPrefix(context.prefix) && $0 != context.prefix }.prefix(12))
    }

    static func insertionSelection(_ command: String, location: Int) -> NSRange {
        let value = command as NSString
        let placeholder = value.range(of: "{}")
        let offset = placeholder.location == NSNotFound ? value.length : placeholder.location + 1
        return NSRange(location: location + offset, length: 0)
    }

    private static func letter(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) }

    /// Conservative delimiter scanner, excluding Markdown code and escaped currency markers.
    static func insideMath(_ units: [UInt16]) -> Bool {
        enum Delimiter { case inlineDollar, displayDollar, paren, bracket }
        var math: Delimiter?, fence: (UInt16, Int)?, codeRun = 0, index = 0, lineStart = true
        while index < units.count {
            let current = units[index], next: UInt16? = index + 1 < units.count ? units[index + 1] : nil
            if lineStart, math == nil, codeRun == 0 {
                var marker = index
                while marker < units.count, units[marker] == 32, marker - index < 4 { marker += 1 }
                if marker - index <= 3, marker < units.count, units[marker] == 96 || units[marker] == 126 {
                    var end = marker
                    while end < units.count, units[end] == units[marker] { end += 1 }
                    let count = end - marker
                    if count >= 3 {
                        if let existing = fence {
                            if existing.0 == units[marker], count >= existing.1 {
                                var trailing = end
                                while trailing < units.count, units[trailing] == 32 || units[trailing] == 9 { trailing += 1 }
                                if trailing == units.count || units[trailing] == 10 || units[trailing] == 13 { fence = nil }
                            }
                        } else { fence = (units[marker], count) }
                        while end < units.count, units[end] != 10 { end += 1 }
                        index = end; lineStart = false; continue
                    }
                }
                if marker - index == 4, fence == nil {
                    while index < units.count, units[index] != 10 { index += 1 }
                    lineStart = false; continue
                }
            }
            if current == 10 || current == 13 {
                if math == .inlineDollar { math = nil }
                lineStart = true; index += 1; continue
            }
            lineStart = false
            if fence != nil { index += 1; continue }
            if current == 96, math == nil {
                var end = index
                while end < units.count, units[end] == 96 { end += 1 }
                let count = end - index
                if codeRun == 0 { codeRun = count } else if count == codeRun { codeRun = 0 }
                index = end; continue
            }
            if codeRun > 0 { index += 1; continue }
            if current == 92, let next {
                if math == nil, next == 40 { math = .paren }
                else if math == nil, next == 91 { math = .bracket }
                else if math == .paren, next == 41 { math = nil }
                else if math == .bracket, next == 93 { math = nil }
                index += 2; continue
            }
            if current == 36 {
                let display = next == 36
                if math == .inlineDollar, !display { math = nil }
                else if math == .displayDollar, display { math = nil }
                else if math == nil {
                    if display { math = .displayDollar }
                    else if let next, next != 32, next != 9, !(48...57).contains(next) { math = .inlineDollar }
                }
                index += display ? 2 : 1; continue
            }
            index += 1
        }
        return math != nil
    }
}
