import XCTest
@testable import OutputLens

@MainActor
final class ReaderPanelControllerTests: XCTestCase {
    func testClosingWindowNotifiesReadingSession() {
        let controller = ReaderPanelController()
        var didClose = false
        controller.onUserClose = { didClose = true }

        controller.window?.performClose(nil)

        XCTAssertTrue(didClose)
    }

    func testRenderAppliesHangingIndentToBullet() {
        let rendered = ReaderPanelController.render("• A long bullet item", proseFontSize: 24)
        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(paragraph?.firstLineHeadIndent, 0)
        XCTAssertNotNil(paragraph)
        XCTAssertEqual(paragraph!.headIndent, 27.6, accuracy: 0.01)
    }

    func testRenderUsesMonospacedFontForInlineCode() {
        let rendered = ReaderPanelController.render("Use `Option-click` here", proseFontSize: 24)
        let font = rendered.attribute(.font, at: 6, effectiveRange: nil) as? NSFont

        XCTAssertEqual(rendered.string, "Use Option-click here")
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    func testRenderRemovesHeadingAndCodeFenceMarkers() {
        let rendered = ReaderPanelController.render("## Heading\n```swift\nlet value = 1\n```", proseFontSize: 24)

        XCTAssertEqual(rendered.string, "Heading\nlet value = 1\n")
    }
}
