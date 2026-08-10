import XCTest
@testable import OutputLens

final class AccessibilitySnapshotTests: XCTestCase {
    func testRedactedFixtureContainsNoAccessibilitySecrets() throws {
        let secret = "token-sk-secret-value"
        let snapshot = TargetSnapshot(
            root: SnapshotNode(
                id: 1,
                role: "AXGroup",
                identifier: "account-\(secret)",
                label: "Conversation: \(secret)",
                text: "Prompt containing \(secret)",
                actionTitles: ["Help for \(secret)"],
                children: [
                    SnapshotNode(
                        id: 2,
                        role: "AXButton",
                        label: "Copy response",
                        actionTitles: ["Copy response", secret]
                    ),
                ]
            ),
            hitNodeID: 2,
            clickPoint: .zero
        )

        let redacted = SnapshotRedaction.redacted(snapshot)
        let encoded = try JSONEncoder().encode(redacted)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("Conversation:"))
        XCTAssertFalse(json.contains("account-"))
        XCTAssertEqual(redacted.root.text, "«redacted chars=39»")
        XCTAssertEqual(redacted.root.children[0].label, "copy response")
        XCTAssertEqual(redacted.root.children[0].actionTitles, ["copy response"])
    }

    func testStructuralSummaryDoesNotDeriveStableContentFingerprint() {
        let snapshot = TargetSnapshot(
            root: SnapshotNode(id: 1, role: "AXStaticText", text: "secret value"),
            hitNodeID: 1,
            clickPoint: .zero
        )

        let summary = SnapshotRedaction.structuralSummary(snapshot)

        XCTAssertTrue(summary.contains("«redacted chars=12»"))
        XCTAssertFalse(summary.contains("secret value"))
        XCTAssertFalse(summary.contains("fp="))
    }
}
