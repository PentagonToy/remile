import AppKit
import XCTest

@testable import Remile

final class MarkdownRenderingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remile-markdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent("image.png"))
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func renderImage(_ source: String) throws -> String {
        var renderer = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
        return try renderer.document(source)
    }

    func testMathMLAndLimits() throws {
        let examples = [
            #"\frac{a+b}{c}"#, #"\sqrt[3]{x_1}"#, #"\sum_{i=1}^{n}i + \int_0^1 x\,dx"#,
            #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#, #"\hat{x} + \mathbf{v} + \alpha \leq \beta"#,
            #"\left\{x^2\right\}"#, #"\frac12"#,
        ]
        for formula in examples {
            let result = try MathMarkup.render(formula, display: true)
            XCTAssertTrue(XMLParser(data: Data(result.utf8)).parse(), "Valid MathML for \(formula)")
        }
        let fraction = try MathMarkup.render(examples[0], display: true)
        XCTAssertTrue(fraction.contains("<mfrac>") && !fraction.contains("\\frac"), "Fraction is structural MathML")
        let matrix = try MathMarkup.render(examples[3], display: true)
        XCTAssertTrue(matrix.components(separatedBy: "<mtr>").count == 3, "Matrix retains two rows")
        for formula in [
            #"\unknown{x}"#, "x^{", "x_1_2",
            String(repeating: "{", count: 140) + "x" + String(repeating: "}", count: 140),
            String(repeating: "x", count: 100_001),
        ] {
            var failed = false
            do { _ = try MathMarkup.render(formula, display: true) } catch { failed = true }
            XCTAssertTrue(failed, "Invalid math fails explicitly")
        }
    }

    func testHTMLSecurityAndLocalImages() throws {
        var renderer = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
        let html = try renderer.document(
            "# Title\n\n| Name | Value |\n| :--- | ---: |\n| Alpha | $x^2$ |\n\n![Local](image.png)\n\n$$\\frac{a}{b}$$\n\n<script>alert('x')</script>"
        )
        XCTAssertTrue(html.contains("<table>") && html.contains("text-align:right"), "Table columns and alignment")
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "Local images embedded as decoded PNG")
        XCTAssertTrue(html.contains("<mfrac>") && html.contains("<msup>"), "Inline and display math both render")
        XCTAssertTrue(!html.contains("<script>"), "Raw source cannot insert scripts")
        XCTAssertTrue(
            html.contains("script-src 'none'") && html.contains("connect-src 'none'"),
            "Self-contained page forbids scripts and network")
        var links = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
        let linkHTML = try links.document(
            "[Reference](https://example.com/paper?q=one&b=two) and [unsafe](javascript:alert)")
        XCTAssertTrue(
            linkHTML.contains("href=\"https://example.com/paper?q=one&amp;b=two\""),
            "Readable links retain escaped destinations")
        XCTAssertTrue(!linkHTML.contains("href=\"javascript:"), "Non-web destinations cannot become active links")
        for source in [
            "![Remote](https://example.invalid/x.png)", "![Escape](../image.png)", "![Missing](missing.png)",
            "```\nunfinished", "$$\nx^2", "",
        ] {
            var failed = false
            do {
                var local = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
                _ = try local.document(source)
            } catch { failed = true }
            XCTAssertTrue(failed, "Invalid or inaccessible resource rejected: \(source)")
        }
    }

    func testPassiveSVGAndHTMLImages() throws {
        let svg =
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 30"><defs><linearGradient id="gold"><stop offset="0" stop-color="#d6b777"/></linearGradient></defs><rect width="40" height="30" fill="url(#gold)"/></svg>"##
        try Data(svg.utf8).write(to: directory.appendingPathComponent("image.svg"))
        let svgHTML = try renderImage("![Vector](image.svg)")
        XCTAssertTrue(
            svgHTML.contains("src=\"data:image/svg+xml;base64,"), "Local SVG embeds as a passive vector image")
        let imageHTML = try renderImage(#"<img src="image.png" alt="A &amp; B" width="960" onerror="alert(1)">"#)
        XCTAssertTrue(
            imageHTML.contains("alt=\"A &amp; B\"") && imageHTML.contains("width=\"960\"")
                && !imageHTML.contains("onerror"), "HTML images retain description and size but discard event handlers")
        let pictureHTML = try renderImage(
            """
            <picture>
              <source media="(prefers-color-scheme: dark)" srcset="image.svg">
              <img src="image.png" alt="Banner" width="960">
            </picture>
            """)
        XCTAssertTrue(
            pictureHTML.contains("class=\"picture-light\"") && pictureHTML.contains("class=\"picture-dark\"")
                && !pictureHTML.contains("&lt;picture"), "Picture selects embedded light and dark images")
        XCTAssertTrue(
            pictureHTML.components(separatedBy: "alt=\"Banner\"").count == 3,
            "Both image variants retain accessible description")
        for code in [
            "\\<img src=\"image.png\">", "`<img src=\"image.png\">`", "``<img src=\"image.png\">``",
            "```html\n<img src=\"image.png\">\n```",
        ] {
            let result = try renderImage(code)
            XCTAssertTrue(!result.contains("src=\"data:image/"), "Image markup remains literal inside code")
        }
        for unsafe in [
            svg.replacingOccurrences(of: "<defs>", with: "<script>alert(1)</script><defs>"),
            svg.replacingOccurrences(of: "viewBox=", with: "onload=\"alert(1)\" viewBox="),
            svg.replacingOccurrences(of: "url(#gold)", with: "url(https://example.invalid/image)"),
            svg.replacingOccurrences(of: "<defs>", with: "<image href=\"file:///etc/passwd\"/><defs>"),
            "<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" + svg,
            "<?xml-stylesheet href=\"https://example.invalid/theme.css\"?>" + svg,
        ] {
            try Data(unsafe.utf8).write(to: directory.appendingPathComponent("unsafe.svg"))
            var failed = false
            do { _ = try renderImage("![Unsafe](unsafe.svg)") } catch { failed = true }
            XCTAssertTrue(failed, "Active or externally referencing SVG rejected")
        }
        for source in [#"<img src="https://example.invalid/x.png">"#, #"<img src="../image.png">"#] {
            var failed = false
            do { _ = try renderImage(source) } catch { failed = true }
            XCTAssertTrue(failed, "HTML image paths use the same local confinement")
        }
    }

    func testRepositoryReadme() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        var renderer = MarkdownHTML(baseURL: readme)
        let result = try renderer.document(String(contentsOf: readme, encoding: .utf8))
        XCTAssertTrue(
            result.components(separatedBy: "src=\"data:image/svg+xml;base64,").count == 3,
            "Actual README embeds both theme banners")
        XCTAssertTrue(
            result.contains("<blockquote>Across time, a few words find you here.</blockquote>"),
            "Actual README slogan remains one sentence")
        try result.write(to: directory.appendingPathComponent("readme.html"), atomically: true, encoding: .utf8)
    }

    func testPreviewFallbackAndStrictExport() throws {
        // A failed figure or unsupported formula must not hide the surrounding reading text.
        let mixed =
            "Before ![remote figure](https://example.invalid/figure.png)\n\n$\\unsupported{x}$ and $x^2$\n\nAfter <img src=\"missing.png\" alt=\"local figure\">"
        var reading = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"), preview: true)
        let readable = try reading.document(mixed)
        XCTAssertTrue(
            readable.contains("Before") && readable.contains("After"), "Preview retains text around unavailable assets")
        XCTAssertTrue(
            reading.unavailableImages == 1 && readable.contains("image unavailable")
                && readable.contains("remile-image:"),
            "Preview routes remote images through the loader and substitutes missing local images")
        XCTAssertTrue(
            reading.literalFormulas == 1 && readable.contains("unsupported") && readable.contains("<math"),
            "Preview preserves unsupported TeX and renders supported maths")
        XCTAssertTrue(!readable.contains("src=\"https://"), "Preview does not bypass the remote image loader")
        var strict = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
        var strictFailed = false
        do { _ = try strict.document(mixed) } catch { strictFailed = true }
        XCTAssertTrue(strictFailed, "Strict export still rejects unavailable content")
    }

    func testPaperNotation() throws {
        for formula in [
            #"x^{\prime} \circ \arccos(y) \ll z \mid t \|u\|"#, #"\begin{equation*}x=1\tag{1}\end{equation*}"#,
            #"\begin{gather*}x=1\\y=2\end{gather*}"#, #"\begin{align*}x&=1\\y&=2\end{align*}"#,
        ] {
            let renderedFormula = try MathMarkup.render(formula, display: true)
            XCTAssertTrue(renderedFormula.contains("<math"))
        }
    }
}
