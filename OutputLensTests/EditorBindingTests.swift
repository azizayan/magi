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
            focus: { _ in focused = true },
            copyForPaste: { _ in XCTFail("Direct apply must not use the clipboard"); return false }
        )

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(written, "updated command")
        XCTAssertTrue(focused)
    }

    func testTerminalApplyCopiesDraftWithoutWritingOrExecuting() {
        let binding = makeBinding(capability: .pasteRequired)
        binding.updateDraft("cargo test")
        var copied = ""

        let result = binding.apply(
            isElementAlive: { _ in true },
            setValue: { _, _ in XCTFail("Paste handoff must not write directly"); return false },
            focus: { _ in XCTFail("Binding must not synthesize terminal input") },
            copyForPaste: { text in copied = text; return true }
        )

        XCTAssertEqual(result, .copiedForPaste)
        XCTAssertEqual(copied, "cargo test")
    }

    func testStaleDirectSourcePreservesDraft() {
        let binding = makeBinding(capability: .direct)
        binding.updateDraft("preserved draft")

        let result = binding.apply(
            isElementAlive: { _ in false },
            setValue: { _, _ in false },
            focus: { _ in },
            copyForPaste: { _ in false }
        )

        XCTAssertEqual(result, .failed("The original input is no longer available. Your draft is preserved here."))
        XCTAssertEqual(binding.draft, "preserved draft")
    }

    func testUnavailableSourceFailsWithoutDiscardingDraft() {
        let binding = makeBinding(capability: .unavailable)

        let result = binding.apply(
            isElementAlive: { _ in true },
            setValue: { _, _ in false },
            focus: { _ in },
            copyForPaste: { _ in false }
        )

        XCTAssertEqual(result, .failed("This input does not support write-back. Your draft is preserved here."))
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
            applicationName: "Test App",
            element: element,
            windowElement: element,
            windowFrame: .zero,
            capability: capability,
            originalText: "original"
        ))
    }
}
