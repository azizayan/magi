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

    func testRenderMakesMarkdownLinkClickable() {
        let rendered = ReaderPanelController.render("See the [docs](https://example.com/guide) now", proseFontSize: 24)

        XCTAssertEqual(rendered.string, "See the docs now")
        let link = rendered.attribute(.link, at: 8, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com/guide"))
    }

    func testRenderLinkifiesBareURL() {
        let rendered = ReaderPanelController.render("Visit https://example.com for details", proseFontSize: 24)

        XCTAssertEqual(rendered.string, "Visit https://example.com for details")
        let link = rendered.attribute(.link, at: 6, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    func testRenderStripsRelativeLinkSyntaxWithoutDeadLink() {
        let rendered = ReaderPanelController.render("Open [CLAUDE.md](CLAUDE.md) here", proseFontSize: 24)

        XCTAssertEqual(rendered.string, "Open CLAUDE.md here")
        XCTAssertNil(rendered.attribute(.link, at: 5, effectiveRange: nil))
    }

    func testRenderDoesNotLinkifyLocalOrApplicationSchemes() {
        for unsafeLink in [
            "[secret](file:///Users/example/private.txt)",
            "[settings](x-apple.systempreferences:com.apple.preference.security)",
            "[script](javascript:alert(1))",
            "ftp://example.com/archive",
        ] {
            let rendered = ReaderPanelController.render(unsafeLink, proseFontSize: 24)
            XCTAssertNil(
                rendered.attribute(.link, at: 0, longestEffectiveRange: nil, in: NSRange(location: 0, length: rendered.length)),
                unsafeLink
            )
        }
    }

    func testSafeWebURLRequiresHTTPWithAHost() {
        XCTAssertNotNil(ReaderPanelController.safeWebURL(URL(string: "HTTPS://example.com/path")!))
        XCTAssertNil(ReaderPanelController.safeWebURL(URL(string: "https:relative")!))
        XCTAssertNil(ReaderPanelController.safeWebURL(URL(fileURLWithPath: "/tmp/private")))
    }

    func testComposeIncludesPromptHeaderWhenEnabled() {
        let rendered = ReaderPanelController.composeReaderContent(
            promptContext: "Explain the build", response: "The build works", showsPrompt: true, proseFontSize: 24
        )

        XCTAssertTrue(rendered.string.contains("PROMPT"))
        XCTAssertTrue(rendered.string.contains("Explain the build"))
        XCTAssertTrue(rendered.string.hasSuffix("The build works"))
    }

    func testComposeOmitsPromptHeaderWhenDisabled() {
        let rendered = ReaderPanelController.composeReaderContent(
            promptContext: "Explain the build", response: "The build works", showsPrompt: false, proseFontSize: 24
        )

        XCTAssertEqual(rendered.string, "The build works")
    }

    func testComposeOmitsPromptHeaderWhenNoPromptAvailable() {
        let rendered = ReaderPanelController.composeReaderContent(
            promptContext: nil, response: "The build works", showsPrompt: true, proseFontSize: 24
        )

        XCTAssertEqual(rendered.string, "The build works")
    }
}
