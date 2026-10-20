import Foundation
import AppKit

var checks = 0
func verify(_ value: @autoclosure () -> Bool, _ name: String) throws {
    guard value() else { throw NSError(domain: "MarkdownChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    checks += 1
}
let examples = [#"\frac{a+b}{c}"#, #"\sqrt[3]{x_1}"#, #"\sum_{i=1}^{n}i + \int_0^1 x\,dx"#, #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#, #"\hat{x} + \mathbf{v} + \alpha \leq \beta"#, #"\left\{x^2\right\}"#, #"\frac12"#]
for formula in examples {
    let result = try MathMarkup.render(formula, display: true)
    try verify(XMLParser(data: Data(result.utf8)).parse(), "Valid MathML for \(formula)")
}
let fraction = try MathMarkup.render(examples[0], display: true)
try verify(fraction.contains("<mfrac>") && !fraction.contains("\\frac"), "Fraction is structural MathML")
let matrix = try MathMarkup.render(examples[3], display: true)
try verify(matrix.components(separatedBy: "<mtr>").count == 3, "Matrix retains two rows")
for formula in [#"\unknown{x}"#, "x^{", "x_1_2", String(repeating: "{", count: 140) + "x" + String(repeating: "}", count: 140), String(repeating: "x", count: 100_001)] {
    var failed = false
    do { _ = try MathMarkup.render(formula, display: true) } catch { failed = true }
    try verify(failed, "Invalid math fails explicitly")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("image.png"))
var renderer = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
let html = try renderer.document("# Title\n\n| Name | Value |\n| :--- | ---: |\n| Alpha | $x^2$ |\n\n![Local](image.png)\n\n$$\\frac{a}{b}$$\n\n<script>alert('x')</script>")
try verify(html.contains("<table>") && html.contains("text-align:right"), "Table columns and alignment")
try verify(html.contains("src=\"data:image/png;base64,"), "Local images embedded as decoded PNG")
try verify(html.contains("<mfrac>") && html.contains("<msup>"), "Inline and display math both render")
try verify(!html.contains("<script>"), "Raw source cannot insert scripts")
try verify(html.contains("script-src 'none'") && html.contains("connect-src 'none'"), "Self-contained page forbids scripts and network")
for source in ["![Remote](https://example.invalid/x.png)", "![Escape](../image.png)", "![Missing](missing.png)", "```\nunfinished", "$$\nx^2", ""] {
    var failed = false
    do { var local = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md")); _ = try local.document(source) } catch { failed = true }
    try verify(failed, "Invalid or inaccessible resource rejected")
}
print("\(checks) Markdown/MathML checks passed")
