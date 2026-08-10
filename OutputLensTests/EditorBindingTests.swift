import XCTest
import ApplicationServices
import Carbon.HIToolbox
@testable import OutputLens

@MainActor
final class EditorBindingTests: XCTestCase {
    private let element = AXUIElementCreateSystemWide()

    func testDirectApplyWritesAndFocusesWithoutSubmitting() {
        let binding = makeBinding(capability: .direct)
        binding.updateDraft("updated command")
        var written = ""
        var focused = false

        let result = binding.apply(
            isElementAlive: { _ in true },
            setValue: { text, _ in written = text; return true },
            focus: { _ in focused = true }
        )

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(written, "updated command")
        XCTAssertTrue(focused)
    }

    func testTerminalApplyCopiesDraftWithoutWritingOrExecuting() {
        let binding = makeBinding(capability: .pasteRequired)
        binding.updateDraft("cargo test")
        let result = binding.apply(
            isElementAlive: { _ in true },
            setValue: { _, _ in XCTFail("Paste handoff must not write directly"); return false },
            focus: { _ in XCTFail("Binding must not synthesize terminal input") }
        )

        XCTAssertEqual(result, .requiresPaste)
    }

    func testStaleDirectSourcePreservesDraft() {
        let binding = makeBinding(capability: .direct)
        binding.updateDraft("preserved draft")

        let result = binding.apply(
            isElementAlive: { _ in false },
            setValue: { _, _ in false },
            focus: { _ in }
        )

        XCTAssertEqual(result, .failed("The original input is no longer available. Your draft is preserved here."))
        XCTAssertEqual(binding.draft, "preserved draft")
    }

    func testUnavailableSourceFailsWithoutDiscardingDraft() {
        let binding = makeBinding(capability: .unavailable)

        let result = binding.apply(
            isElementAlive: { _ in true },
            setValue: { _, _ in false },
            focus: { _ in }
        )

        XCTAssertEqual(result, .failed("This input does not support write-back. Your draft is preserved here."))
    }

    func testTemporaryPasteRestoresEveryPreviousItemAndType() throws {
        let pasteboard = NSPasteboard(name: .init("MagiTests.restore.\(UUID())"))
        let first = NSPasteboardItem()
        first.setString("previous text", forType: .string)
        first.setData(Data([0x01, 0x02]), forType: .init("com.example.binary"))
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let transaction = try XCTUnwrap(PasteboardTransaction(text: "private draft", pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "private draft")

        XCTAssertTrue(transaction.restoreIfOwned())
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "previous text")
        XCTAssertEqual(items[0].data(forType: .init("com.example.binary")), Data([0x01, 0x02]))
        XCTAssertEqual(items[1].string(forType: .string), "second item")
    }

    func testTemporaryPasteDoesNotOverwriteAConcurrentClipboardChange() throws {
        let pasteboard = NSPasteboard(name: .init("MagiTests.concurrent.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(text: "private draft", pasteboard: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)

        XCTAssertFalse(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testTerminalReplacementClearsBeforePasteAndNeverPressesReturn() {
        let strokes = AccessibilityClient.terminalReplacementKeystrokes

        XCTAssertEqual(strokes.map(\.keyCode), [
            CGKeyCode(kVK_ANSI_E),
            CGKeyCode(kVK_ANSI_U),
            CGKeyCode(kVK_ANSI_V),
        ])
        XCTAssertEqual(strokes.map(\.flags), [.maskControl, .maskControl, .maskCommand])
        XCTAssertFalse(strokes.map(\.keyCode).contains(CGKeyCode(kVK_Return)))
    }

    private func makeBinding(capability: WriteBackCapability) -> EditorBinding {
        EditorBinding(source: EditorSource(
            applicationPID: 1,
            bundleIdentifier: "com.example.test",
            applicationName: "Test App",
            element: element,
            windowElement: element,
            windowFrame: .zero,
            capability: capability,
            originalText: "original"
        ))
    }
}
