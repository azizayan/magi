import XCTest
import AppKit
@testable import OutputLens

@MainActor
final class ClipboardReaderTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.azizemreayan.magi.tests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testDoesNotSurfacePreExistingClipboardContent() {
        pasteboard.clearContents()
        pasteboard.setString("already copied before watching", forType: .string)

        let reader = ClipboardReader(pasteboard: pasteboard)
        var surfaced: [String] = []
        reader.onNewText = { surfaced.append($0) }

        XCTAssertNil(reader.checkForChange())
        XCTAssertTrue(surfaced.isEmpty)
    }

    func testSurfacesTextCopiedAfterStart() {
        let reader = ClipboardReader(pasteboard: pasteboard)
        var surfaced: [String] = []
        reader.onNewText = { surfaced.append($0) }

        pasteboard.clearContents()
        pasteboard.setString("a fresh response", forType: .string)

        XCTAssertEqual(reader.checkForChange(), "a fresh response")
        XCTAssertEqual(surfaced, ["a fresh response"])
    }

    func testDoesNotRefireWithoutAChange() {
        let reader = ClipboardReader(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("one copy", forType: .string)

        XCTAssertEqual(reader.checkForChange(), "one copy")
        XCTAssertNil(reader.checkForChange())
    }

    func testCaptureNowSurfacesCurrentText() {
        pasteboard.clearContents()
        pasteboard.setString("manual capture", forType: .string)

        let reader = ClipboardReader(pasteboard: pasteboard)
        var surfaced: [String] = []
        reader.onNewText = { surfaced.append($0) }

        reader.captureNow()

        XCTAssertEqual(surfaced, ["manual capture"])
    }

    func testCanIgnoreClipboardWritePerformedByEditor() {
        let reader = ClipboardReader(pasteboard: pasteboard)
        var surfaced: [String] = []
        reader.onNewText = { surfaced.append($0) }

        pasteboard.clearContents()
        pasteboard.setString("terminal draft", forType: .string)
        reader.ignoreCurrentChange()

        XCTAssertNil(reader.checkForChange())
        XCTAssertTrue(surfaced.isEmpty)
    }
}
