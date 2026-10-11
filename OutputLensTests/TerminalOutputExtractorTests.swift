import XCTest
@testable import OutputLens

final class TerminalOutputExtractorTests: XCTestCase {
    func testExtractsClickedOutputBetweenPrompts() {
        let text = "user@mac ~/repo % make test\nline one\nline two\nuser@mac ~/repo % git status\nclean\n"
        let clicked = (text as NSString).range(of: "line two").location

        XCTAssertEqual(
            TerminalOutputExtractor.block(in: text, characterIndex: clicked),
            "line one\nline two"
        )
    }

    func testClickingPromptDoesNotReturnTerminalHistory() {
        let text = "$ echo hello\nhello\n$ next-command\n"
        let clicked = (text as NSString).range(of: "$ next-command").location

        XCTAssertNil(TerminalOutputExtractor.block(in: text, characterIndex: clicked))
    }

    func testUnboundedTextFailsClosed() {
        XCTAssertNil(TerminalOutputExtractor.block(
            in: "one\ntwo\nthree",
            characterIndex: 5
        ))
    }

    func testOneSidedPromptFailsClosedInsteadOfReturningHistory() {
        let text = "$ command\nfirst line\nstill running\n"
        let clicked = (text as NSString).range(of: "first line").location

        XCTAssertNil(TerminalOutputExtractor.block(in: text, characterIndex: clicked))
    }
}
