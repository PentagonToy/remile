import XCTest
@testable import Remile

final class TeXMathEditingTests: XCTestCase {
    private func input(_ markedSource: String) -> (String, NSRange) {
        let marker = (markedSource as NSString).range(of: "¦")
        precondition(marker.location != NSNotFound)
        return (markedSource.replacingOccurrences(of: "¦", with: ""), NSRange(location: marker.location, length: 0))
    }

    func testSubscriptPairsInTeXMathAndUsesUTF16Offsets() throws {
        for example in [#"한글 🌊 $u¦$"#, "$$\nu¦\n$$", #"\(u¦\)"#, #"\[u¦\]"#, #"\begin{equation}u¦\end{equation}"#, #"\begin{align*}u¦ &= v\end{align*}"#] {
            let (source, selection) = input(example)
            let change = try XCTUnwrap(TeXMathEditing.scriptChange(source, selection: selection, marker: "_"), example)
            XCTAssertEqual(change.range, selection)
            XCTAssertEqual(change.text, "_{}")
            XCTAssertEqual(change.selection, NSRange(location: selection.location + 2, length: 0))
        }
    }

    func testSubscriptLeavesPlainTextAndLiteralArgumentsAlone() {
        for example in [#"file¦name"#, #"$u$ file¦name"#, #"$u\¦$"#, #"$u¦{t}$"#, #"$\text{a{b¦c}}$"#,
                        #"$u \label{eq¦name}$"#, #"\verb|$u¦$|"#, #"\begin{verbatim}$u¦$\end{verbatim}"#,
                        #"$u % ignore¦$"#, #"% $u¦"#, #"\$u¦"#] {
            let (source, selection) = input(example)
            XCTAssertNil(TeXMathEditing.scriptChange(source, selection: selection, marker: "_"), example)
        }
    }

    func testSuperscriptAndTabNavigation() throws {
        let (power, insertion) = input(#"$x¦$"#)
        let change = try XCTUnwrap(TeXMathEditing.scriptChange(power, selection: insertion, marker: "^"))
        XCTAssertEqual(change.text, "^{}")

        for (example, distance) in [
            (#"$x_{t¦}$"#, 1), (#"$x^{n¦}$"#, 1),
            (#"$\frac{\sqrt{x}¦}{y}$"#, 2), (#"$\frac{x}{y¦}$"#, 1),
            (#"$\sqrt{x¦}$"#, 1)
        ] {
            let (source, selection) = input(example)
            XCTAssertEqual(TeXMathEditing.tabDestination(source, selection: selection), selection.location + distance, example)
        }

        for example in [#"x_{t¦}"#, #"$\text{x¦}$"#, #"$\label{eq¦}$"#, #"$x_{t¦i}$"#, #"$x {t¦}$"#] {
            let (source, selection) = input(example)
            XCTAssertNil(TeXMathEditing.tabDestination(source, selection: selection), example)
        }
    }

    func testPreviewRendersTheWholeActiveFormula() throws {
        let (source, selection) = input("Text $a$.\n\\begin{align}\nu_{¦t} &= v % ignore this\n\\label{eq:velocity}\\end{align}\n")
        let formula = try XCTUnwrap(TeXMathEditing.formula(source, selection: selection))
        XCTAssertTrue(formula.display)
        XCTAssertEqual(formula.source, #"\begin{align}u_{t} &= v\end{align}"#)
        let markup = try MathMarkup.render(formula.source, display: formula.display)
        XCTAssertTrue(markup.contains("<mtable"))
        XCTAssertTrue(markup.contains("<msub>"))
        let (inline, caret) = input(#"Text $x¦=2$ and $y=3$."#)
        XCTAssertEqual(TeXMathEditing.formula(inline, selection: caret)?.source, "x=2")
    }

    func testAlignHighlightsTheActiveEquationRowAndPreservesLiteralIndices() throws {
        let (source, caret) = input("\\begin{align}\nu_{xx} &= 1 \\\\ % comment\n v¦ &= 2\\end{align}")
        let formula = try XCTUnwrap(TeXMathEditing.formula(source, selection: caret))
        let markup = try MathMarkup.render(formula.source, display: true, highlightOffset: formula.highlightOffset)
        let firstRow = try XCTUnwrap(markup.range(of: "<msub>"))
        let highlight = try XCTUnwrap(markup.range(of: "active-equation-row"))
        let secondRow = try XCTUnwrap(markup.range(of: "<mi>v</mi>"))
        XCTAssertLessThan(firstRow.lowerBound, highlight.lowerBound)
        XCTAssertLessThan(highlight.lowerBound, secondRow.lowerBound)
        XCTAssertTrue(markup.contains("<mi>x</mi><mi>x</mi>"))
        XCTAssertFalse(markup.contains("×"))
    }

    func testPreviewCanFollowAnUnclosedFormulaWhileTyping() throws {
        let (source, selection) = input(#"Text $u_{¦}"#)
        let formula = try XCTUnwrap(TeXMathEditing.formula(source, selection: selection))
        XCTAssertEqual(formula.source, "u_{}")
        XCTAssertTrue(try MathMarkup.render(formula.source, display: formula.display).contains("<msub>"))
        let (prose, caret) = input(#"$u_t$ prose¦"#)
        XCTAssertNil(TeXMathEditing.formula(prose, selection: caret))
    }
}
