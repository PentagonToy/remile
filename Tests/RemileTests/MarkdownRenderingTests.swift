import AppKit
import WebKit
import XCTest

@testable import Remile

final class MarkdownRenderingTests: XCTestCase {
    func testPreviewMarksFormattedExternalLinkOnce() throws {
        let source = "[Read the **paper**](https://example.invalid) and [unsafe](javascript:alert)"
        let url = directory.appendingPathComponent("fixture.md")
        var preview = MarkdownHTML(baseURL: url, preview: true)
        let html = try preview.document(source)
        XCTAssertTrue(html.contains(#"<a href="https://example.invalid" data-browser-link aria-description="Opens in your browser">"#))
        XCTAssertEqual(html.components(separatedBy: "<a href=").count - 1, 1)
        XCTAssertFalse(html.contains("href=\"javascript:"))
        var export = MarkdownHTML(baseURL: url)
        let exported = try export.document(source)
        XCTAssertTrue(exported.contains(#"<a href="https://example.invalid">"#))
        XCTAssertFalse(exported.contains("data-browser-link"))
    }

    @MainActor func testPreviewNavigationOnlyOpensClickedWebLinksWhenOnline() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.invalid/paper"))
        let local = URL(fileURLWithPath: "/tmp/fixture.md")
        var opened: [URL] = []
        let open: (URL) -> Void = { opened.append($0) }
        XCTAssertEqual(MarkdownPreviewNavigation.policy(for: .linkActivated, url: destination, offline: false, open: open), .cancel)
        XCTAssertEqual(MarkdownPreviewNavigation.policy(for: .linkActivated, url: destination, offline: true, open: open), .cancel)
        XCTAssertEqual(MarkdownPreviewNavigation.policy(for: .linkActivated, url: local, offline: false, open: open), .cancel)
        XCTAssertEqual(MarkdownPreviewNavigation.policy(for: .other, url: destination, offline: false, open: open), .cancel)
        XCTAssertEqual(MarkdownPreviewNavigation.policy(for: .other, url: URL(string: "about:blank"), offline: true, open: open), .allow)
        XCTAssertEqual(opened, [destination])
    }

    func testOutlineAnchorsMatchIndexedSections() {
        for source in ["", "\n \t\n# First\nText", "Intro\r\n# First\r\n~~~\r\n## Hidden\r\n~~~\r\n## Second"] {
            let headings = SearchMarkdown.headings(source)
            let sections = SearchMarkdown.sections(source)
            XCTAssertEqual(headings.map(\.number), sections.map(\.number))
            XCTAssertEqual(headings.map(\.line), sections.map(\.line))
            XCTAssertEqual(headings.map(\.title), sections.map(\.title))
        }
        XCTAssertEqual(SearchMarkdown.headings("\n \t\n# First\nText").map(\.line), [2])
        XCTAssertEqual(SearchMarkdown.headings("Intro\n# First\n~~~\n## Hidden\n~~~\n## Second").map(\.line), [0, 1, 5])
    }

    func testMathPasteNormalisesExplicitDelimitersAndPreservesCode() {
        let input = #"""
        속도 \(u_{xx}\)입니다.
        \[
        \begin{aligned} a &= b \\ c &= d \end{aligned}
        \]
        `\(literal\)` and $x+\(existing\)$
        > ~~~~tex
        > \[example\]
        > ~~~~
        """#
        let expected = #"""
        속도 $u_{xx}$입니다.
        $$
        \begin{aligned} a &= b \\ c &= d \end{aligned}
        $$
        `\(literal\)` and $x+\(existing\)$
        > ~~~~tex
        > \[example\]
        > ~~~~
        """#
        XCTAssertEqual(MarkdownMathPaste.normalised(input), expected)
        XCTAssertNil(MarkdownMathPaste.normalised(#"\\(escaped\\) (ordinary) [ordinary] \[unfinished"#))
        let before = "Example\n~~~tex\n"
        let selection = NSRange(location: before.utf16.count, length: 0)
        XCTAssertNil(MarkdownMathPaste.normalised(#"\[x\]"#, in: before + "\n~~~", replacing: selection))
    }

    func testTeXMathSuggestionsHaveNativePreviewsAndKeepSourceCommands() throws {
        let source = "$\\d$"
        let completion = try XCTUnwrap(EditorCompletion.context(source, selection: NSRange(location: 3, length: 0), tex: true))
        let previews = completion.items.compactMap { item in MathMarkup.completionPreview(item.label) }
        XCTAssertTrue(previews.contains("δ"))
        XCTAssertTrue(previews.contains("÷"))
        XCTAssertTrue(previews.contains("↓"))
        let delta = try XCTUnwrap(completion.items.first { $0.label == "\\delta" })
        XCTAssertEqual((source as NSString).replacingCharacters(in: completion.range, with: delta.insertion), "$\\delta$")

        let prefix = #"$\canc"#
        let markdown = try XCTUnwrap(EditorCompletion.context(prefix + "$", selection: NSRange(location: prefix.utf16.count, length: 0), tex: false))
        let cancel = try XCTUnwrap(markdown.items.first { $0.label == #"\cancel{}"# })
        XCTAssertEqual(cancel.insertion, #"\cancel{}"#)
        XCTAssertEqual(cancel.caret, 8)
    }
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

    func testPreviewRendersMappingAndBoxedFormula() throws {
        let source = #"""
        $$
        s \longmapsto \bigl(c,\rho,T,Z,\omega_c,\boldsymbol Y\bigr)(s)
        $$

        $$
        \beta=\frac{Y_{\mathrm H}^{\mathrm{elem}}}{2W_{\mathrm H}}
        -\frac{Y_{\mathrm O}^{\mathrm{elem}}}{W_{\mathrm O}},\qquad
        \boxed{Z=\frac{\beta-\beta_{\mathrm{ox}}}
        {\beta_{\mathrm{fuel}}-\beta_{\mathrm{ox}}}}.
        $$

        For $a\equiv b\pmod{n}$, write $\overrightarrow{AB}$.
        """#
        var preview = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"), preview: true)
        let html = try preview.document(source)
        XCTAssertEqual(preview.literalFormulas, 0)
        XCTAssertTrue(html.contains("<mo>⟼</mo>"))
        XCTAssertTrue(html.contains(#"<mrow style="border:1px solid currentColor;padding:0.15em"><mrow><mi>Z</mi><mo>=</mo><mfrac>"#))
        XCTAssertTrue(html.contains("<mtext>mod</mtext>"))
        XCTAssertTrue(html.contains(#"<mo stretchy="true">→</mo>"#))
        XCTAssertFalse(html.contains("math-source"))
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
        XCTAssertTrue(readable.contains(#"title="Unsupported formula command: \unsupported""#))
        XCTAssertTrue(!readable.contains("src=\"https://"), "Preview does not bypass the remote image loader")
        var strict = MarkdownHTML(baseURL: directory.appendingPathComponent("fixture.md"))
        var strictFailed = false
        do { _ = try strict.document(mixed) } catch { strictFailed = true }
        XCTAssertTrue(strictFailed, "Strict export still rejects unavailable content")
    }

    func testPaperNotation() throws {
        let additions = [
            (#"\operatorname*{arg\,min}_{x\in X} f(x)"#, "<munder>"),
            (#"\sum_{\substack{i>0\\j>0}} a_{ij}"#, "<mtable>"),
            (#"X\xrightarrow[n\to\infty]{\mathrm{law}}Y"#, "<munderover>"),
            (#"\overset{!}{=}\;\underset{x}{\min}\;\overbrace{x+y}^{s}"#, "⏞"),
            (#"\begin{equation}\begin{split}x&=1\\y&=2\end{split}\end{equation}"#, "columnalign"),
            (#"\begin{aligned}x&=\begin{pmatrix}a&b\\c&d\end{pmatrix}\\y&=2\notag\end{aligned}"#, "<mi>d</mi>"),
            (#"\begin{aligned}\{x&=1\\y&=2\end{aligned}"#, "<mi>y</mi>"),
            (#"\bm{u}\coloneqq\mathfrak{X}\setminus\varnothing\;\dotsb"#, "≔"),
            (#"\overrightarrow{AB}"#, #"<mo stretchy="true">→</mo>"#),
            (#"a\equiv b\pmod{n}"#, #"<mo>(</mo><mtext>mod</mtext>"#),
            (#"\left\langle x\middle|y\right\rangle"#, #"<mo stretchy="true">|</mo>"#),
            (#"\begin{alignedat}[t]{2} a&=b & c&=d\\ e&=f & g&=h\end{alignedat}"#, #"<mi>h</mi>"#),
            (#"x\nRightarrow \nexists y"#, "<mo>⇏</mo><mo>∄</mo>"),
            (#"\oiint_{S} \vec{u}\cdot\hat{n}\,\mathrm{d}S"#, "<mo>∯</mo>"),
            (#"\dddot{x}+\mathring{q}"#, "<mo>⃛</mo>"),
            (#"\xcancel{a+b}"#, #"<menclose notation="updiagonalstrike downdiagonalstrike">"#),
            (#"\textbf{fuel & air}"#, #"<mtext style="font-weight:bold">fuel &amp; air</mtext>"#),
            (#"x=1\tag*{A}"#, "<mtext>A</mtext>"),
        ]
        for (formula, marker) in additions {
            let rendered = try MathMarkup.render(formula, display: true)
            XCTAssertTrue(rendered.contains(marker), formula)
            XCTAssertTrue(XMLParser(data: Data(rendered.utf8)).parse(), formula)
        }
        let array = try MathMarkup.render(#"\left[\begin{array}[t]{lcr}a&b&c\\d&e&f\end{array}\right]"#, display: true)
        XCTAssertTrue(array.contains(#"<mtd style="text-align:left"><mrow><mi>a</mi>"#))
        XCTAssertTrue(array.contains(#"<mtd style="text-align:center"><mrow><mi>b</mi>"#))
        XCTAssertTrue(array.contains(#"<mtd style="text-align:right"><mrow><mi>f</mi>"#))
        XCTAssertThrowsError(try MathMarkup.render(#"\begin{array}{l|c}a&b\end{array}"#, display: true))
        XCTAssertThrowsError(try MathMarkup.render(#"\begin{array}{l}a&b\end{array}"#, display: true))
        XCTAssertThrowsError(try MathMarkup.render(String(repeating: #"\sqrt "#, count: 200) + "x", display: true))
        XCTAssertThrowsError(try MathMarkup.render("{{x}", display: true))
        XCTAssertThrowsError(try MathMarkup.render(#"x\limitsextra"#, display: true))
        let inline = try MathMarkup.render(#"{\displaystyle\sum_i}\sum_j\int\limits_0^1"#, display: false)
        XCTAssertTrue(inline.contains("<munder><mo>∑</mo><mi>i</mi></munder></mstyle></mrow><msub>"))
        XCTAssertTrue(inline.contains("<munderover><mo>∫</mo><mn>0</mn><mn>1</mn></munderover>"))
        let fractions = try MathMarkup.render(#"\dfrac12+\tfrac34"#, display: true)
        XCTAssertTrue(fractions.contains(#"<mstyle displaystyle="true"><mfrac><mn>1</mn><mn>2</mn>"#))
        XCTAssertTrue(fractions.contains(#"<mstyle displaystyle="false"><mfrac><mn>3</mn><mn>4</mn>"#))
        for formula in [
            #"x^{\prime} \circ \arccos(y) \ll z \mid t \|u\|"#, #"\begin{equation*}x=1\tag{1}\end{equation*}"#,
            #"\begin{gather*}x=1\\y=2\end{gather*}"#, #"\begin{align*}x&=1\\y&=2\end{align*}"#,
        ] {
            let renderedFormula = try MathMarkup.render(formula, display: true)
            XCTAssertTrue(renderedFormula.contains("<math"))
        }
    }

    func testPaperMathWithLabelsAndMultilineEquations() throws {
        let source = #"""
        $$
        \begin{align}
        x &= 1 + \cfrac{1}{2+\cfrac{1}{3}}\label{eq:first}\\
        a &\not\equiv b \iff 0 \lt a \land b \ncong c
        \end{align}
        $$

        $$
        \begin{multline*}
        a+b+c \\
        +d+e \\
        = f \quad \textup{heat \& mass (10\%)}
        \end{multline*}
        $$
        """#
        let file = directory.appendingPathComponent("fixture.md")
        var preview = MarkdownHTML(baseURL: file, preview: true)
        let html = try preview.document(source)
        XCTAssertEqual(preview.literalFormulas, 0)
        XCTAssertEqual(html.components(separatedBy: "<mfrac>").count - 1, 2)
        XCTAssertTrue(html.contains("<mo>≢</mo>"))
        XCTAssertTrue(html.contains("<mo>≇</mo>"))
        XCTAssertTrue(html.contains("<mo>&lt;</mo>"))
        XCTAssertFalse(html.contains("eq:first"))
        XCTAssertTrue(html.contains(#"<mtd style="text-align:left"><mrow><mi>a</mi><mo>+</mo><mi>b</mi>"#))
        XCTAssertTrue(html.contains(#"<mtd style="text-align:center"><mrow><mo>+</mo><mi>d</mi>"#))
        XCTAssertTrue(html.contains(#"<mtd style="text-align:right"><mrow><mo>=</mo><mi>f</mi>"#))
        XCTAssertTrue(html.contains("<mtext>heat &amp; mass (10%)</mtext>"))
        var export = MarkdownHTML(baseURL: file)
        XCTAssertEqual(try export.document(source).components(separatedBy: "</style></head><body>").last,
                       html.components(separatedBy: "</style></head><body>").last)

        XCTAssertThrowsError(try MathMarkup.render(#"x\not\frac{1}{2}"#, display: false))
        XCTAssertThrowsError(try MathMarkup.render(#"\cfrac[l]{1}{2}"#, display: true))
        XCTAssertThrowsError(try MathMarkup.render(#"\label{x"#, display: true))
    }

    func testExtendedMathRendersInPreviewAndExport() throws {
        let source = #"""
        The states $A\xrightleftharpoons[k_{-1}]{k_1}B$ are in equilibrium.

        $$
        \biguplus_{i=1}^{n} A_i \xmapsto{f} \llbracket X\rrbracket
        \hphantom{X}\vphantom{\frac{1}{2}}\mathstrut.
        $$
        """#
        let file = directory.appendingPathComponent("fixture.md")
        var preview = MarkdownHTML(baseURL: file, preview: true)
        let html = try preview.document(source)
        XCTAssertEqual(preview.literalFormulas, 0)
        for marker in [
            #"<munderover><mo stretchy="true">⇌</mo>"#,
            "<munderover><mo>⨄</mo>",
            #"<mover><mo stretchy="true">↦</mo>"#,
            "<mo>⟦</mo>",
            #"<mpadded height="0" depth="0"><mphantom>"#,
            #"<mpadded width="0"><mphantom><mo>(</mo>"#,
        ] {
            XCTAssertTrue(html.contains(marker), marker)
        }
        var export = MarkdownHTML(baseURL: file)
        XCTAssertEqual(try export.document(source).components(separatedBy: "</style></head><body>").last,
                       html.components(separatedBy: "</style></head><body>").last)
        XCTAssertTrue(MathCompletion.suggestions(.init(range: .init(location: 0, length: 3), prefix: #"\xm"#))
            .contains(#"\xmapsto{}"#))
        XCTAssertThrowsError(try MathMarkup.render(#"A\xmapsto[missing B"#, display: false))
    }

    func testMathArrowsAndLayoutInPreviewAndExport() throws {
        let source = #"""
        Inline $\lim\displaylimits_{n\to\infty} a_n$.

        $$
        \lim\displaylimits_{n\to\infty} a_n \approxeq
        A\rightharpoonup B\twoheadrightarrow C\multimap D\boxplus E
        \smash[t]{\frac{1}{2}}
        $$
        """#
        let file = directory.appendingPathComponent("fixture.md")
        var preview = MarkdownHTML(baseURL: file, preview: true)
        var export = MarkdownHTML(baseURL: file)
        let html = try preview.document(source)
        let exported = try export.document(source)
        XCTAssertEqual(preview.literalFormulas, 0)
        for marker in [
            "<msub><mi>lim</mi>", "<munder><mi>lim</mi>", "<mo>≊</mo>", "<mo>⇀</mo>",
            "<mo>↠</mo>", "<mo>⊸</mo>", "<mo>⊞</mo>", #"<mpadded height="0"><mrow><mfrac>"#,
        ] {
            XCTAssertTrue(html.contains(marker), marker)
            XCTAssertTrue(exported.contains(marker), marker)
        }
        XCTAssertTrue(try MathMarkup.render(#"\smash[b]{x}\smash{x}"#, display: true)
            .contains(#"<mpadded depth="0"><mrow><mi>x</mi></mrow></mpadded><mpadded height="0" depth="0">"#))
        XCTAssertThrowsError(try MathMarkup.render(#"\smash[bad]{x}"#, display: true))
        let command = #"\rightharpoonup"#
        let context = MathCompletion.Context(range: NSRange(location: 0, length: 6), prefix: #"\right"#)
        XCTAssertTrue(MathCompletion.suggestions(context).contains(command))
        XCTAssertEqual(MathMarkup.completionPreview(command), "⇀")
    }
}
