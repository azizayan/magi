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

    func testTerminalHelperResolvesToSupportedParentApplication() {
        let warp = ApplicationIdentity(
            processIdentifier: 822,
            bundleIdentifier: "dev.warp.Warp-Stable",
            name: "Warp"
        )
        let parents: [pid_t: pid_t] = [1079: 822, 822: 1]

        let resolved = SupportedApplication.resolveOwner(
            startingAt: 1079,
            applicationIdentity: { $0 == 822 ? warp : nil },
            parentProcessIdentifier: { parents[$0] ?? 0 }
        )

        XCTAssertEqual(resolved, warp)
    }
}
