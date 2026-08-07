import XCTest
@testable import OutputLens

final class SupportedApplicationTests: XCTestCase {
    func testWarpIsRecognizedAsATerminal() {
        XCTAssertTrue(SupportedApplication.isTerminal(
            bundleIdentifier: "dev.warp.Warp-Stable",
            applicationName: "Warp"
        ))
    }

    func testKnownTerminalNameSupportsUnlistedBundleVariant() {
        XCTAssertTrue(SupportedApplication.isSupported(
            bundleIdentifier: "example.preview-build",
            applicationName: "Ghostty"
        ))
    }

    func testUnrelatedApplicationIsRejected() {
        XCTAssertFalse(SupportedApplication.isSupported(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari"
        ))
    }
}
