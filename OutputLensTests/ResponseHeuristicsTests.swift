import XCTest
import ApplicationServices
@testable import OutputLens

final class ResponseHeuristicsTests: XCTestCase {
    func testCopyCodeControlIsNotMistakenForResponseBoundary() {
        let markers = CodexResponseAdapter().markers
        XCTAssertFalse(markers.matches(["Copy code"]))
        XCTAssertTrue(markers.matches(["Copy response"]))
        XCTAssertTrue(markers.matches(["Show message actions"]))
    }

    func testSafeUpdateAcceptsStreamingAppend() {
        XCTAssertTrue(ResponseHeuristics.isSafeUpdate(previous: "A sufficiently long response begins here", next: "A sufficiently long response begins here and continues"))
    }

    func testSafeUpdateRejectsDifferentResponse() {
        XCTAssertFalse(ResponseHeuristics.isSafeUpdate(previous: "First response with enough identifying text", next: "Second response with completely different text"))
    }

    func testNormalizePreservesCodeIndentation() {
        XCTAssertEqual(ResponseHeuristics.normalize("\n  if true {\n    run()\n  }\n"), "if true {\n    run()\n  }")
    }

    func testAssembleJoinsFragmentsOnTheSameVisualLine() {
        let fragments = [
            fragment("•", x: 0, y: 10),
            fragment("Added", x: 20, y: 10),
            fragment("A−", x: 80, y: 10),
            fragment("and", x: 110, y: 10),
            fragment("A+", x: 150, y: 10),
            fragment("controls.", x: 180, y: 10),
        ]

        XCTAssertEqual(ResponseHeuristics.assemble(fragments), "• Added A− and A+ controls.")
    }

    func testAssembleKeepsDifferentVisualLinesSeparate() {
        let fragments = [
            fragment("First line", x: 0, y: 10),
            fragment("Second line", x: 0, y: 40),
        ]

        XCTAssertEqual(ResponseHeuristics.assemble(fragments), "First line\nSecond line")
    }

    func testAssembleDoesNotInsertSpaceBeforePunctuation() {
        let fragments = [fragment("Hello", x: 0, y: 10), fragment(",", x: 50, y: 10), fragment("world", x: 60, y: 10)]

        XCTAssertEqual(ResponseHeuristics.assemble(fragments), "Hello, world")
    }

    func testAssemblePreservesAccessibilityHeadingSemantics() {
        let fragments = [
            fragment("Current situation", x: 0, y: 10, role: kAXHeadingRole as String),
            fragment("Body text", x: 0, y: 40),
        ]

        XCTAssertEqual(ResponseHeuristics.assemble(fragments), "## Current situation\nBody text")
    }

    func testAssemblePrefersPlainDuplicateForAccessibleResponseLabel() {
        let fragments = [
            fragment("Claude responded: Opening", x: 0, y: 10, role: kAXHeadingRole as String),
            fragment("Claude responded: Opening", x: 0, y: 10),
        ]

        XCTAssertEqual(ResponseHeuristics.assemble(fragments), "Claude responded: Opening")
    }

    private func fragment(_ text: String, x: CGFloat, y: CGFloat, role: String = kAXStaticTextRole as String) -> ResponseTextFragment {
        ResponseTextFragment(text: text, frame: CGRect(x: x, y: y, width: 40, height: 20), role: role)
    }
}
