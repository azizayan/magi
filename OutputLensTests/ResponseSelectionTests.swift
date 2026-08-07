import XCTest
@testable import OutputLens

/// Fixture-driven tests for message-boundary selection. The fixtures model the
/// two tree shapes seen in Codex and Claude: per-message containers, and a
/// flat conversation whose messages and action rows are all siblings.
final class ResponseSelectionTests: XCTestCase {
    private let adapter = CodexResponseAdapter()

    // MARK: - Fixture builders

    private func paragraph(id: Int, _ text: String, y: CGFloat, height: CGFloat = 30) -> SnapshotNode {
        SnapshotNode(
            id: id,
            role: "AXStaticText",
            text: text,
            frame: CGRect(x: 20, y: y, width: 600, height: height)
        )
    }

    private func copyButton(id: Int, label: String = "Copy response", y: CGFloat) -> SnapshotNode {
        SnapshotNode(
            id: id,
            role: "AXButton",
            label: label,
            frame: CGRect(x: 20, y: y, width: 28, height: 20),
            actionTitles: [label]
        )
    }

    private func actionRow(id: Int, buttonIDs: [Int], label: String = "Copy response", y: CGFloat) -> SnapshotNode {
        SnapshotNode(
            id: id,
            role: "AXGroup",
            frame: CGRect(x: 20, y: y, width: 200, height: 20),
            children: buttonIDs.map { copyButton(id: $0, label: label, y: y) }
        )
    }

    /// Flat conversation modelling the real Claude tree: a conversation
    /// container holding a message-list node (its children are the turns, each
    /// group owning its text and Copy button) plus a full-size transparent
    /// overlay — which is what the click actually lands on. A streaming tail
    /// turn has no control yet. Clicks pass `overlayHitID` and are located by
    /// the click Y against the real leaf frames.
    static let overlayHitID = 9

    private func flatConversation(streamingTail: String? = nil) -> SnapshotNode {
        var turns: [SnapshotNode] = [
            SnapshotNode(id: 10, role: "AXGroup", frame: CGRect(x: 20, y: 100, width: 600, height: 60), children: [
                paragraph(id: 11, "User asked a question about builds", y: 100, height: 40),
                copyButton(id: 13, label: "Copy message", y: 150),
            ]),
            SnapshotNode(id: 20, role: "AXGroup", frame: CGRect(x: 20, y: 200, width: 600, height: 90), children: [
                paragraph(id: 21, "First response paragraph", y: 200),
                paragraph(id: 22, "First response continues", y: 240),
                copyButton(id: 24, y: 280),
            ]),
            SnapshotNode(id: 30, role: "AXGroup", frame: CGRect(x: 20, y: 330, width: 600, height: 90), children: [
                paragraph(id: 31, "Second response paragraph", y: 330),
                paragraph(id: 32, "Second response continues", y: 370),
                copyButton(id: 34, y: 410),
            ]),
        ]
        if let streamingTail {
            turns.append(
                SnapshotNode(id: 40, role: "AXGroup", frame: CGRect(x: 20, y: 460, width: 600, height: 40), children: [
                    paragraph(id: 41, streamingTail, y: 460, height: 40),
                ])
            )
        }
        let height: CGFloat = streamingTail == nil ? 400 : 500
        let messageList = SnapshotNode(id: 5, role: "AXGroup", frame: CGRect(x: 20, y: 80, width: 600, height: height), children: turns)
        let overlay = SnapshotNode(id: Self.overlayHitID, role: "AXGroup", frame: CGRect(x: 20, y: 80, width: 600, height: height))
        return SnapshotNode(
            id: 1,
            role: "AXGroup",
            identifier: "conversation",
            frame: CGRect(x: 0, y: 80, width: 640, height: height),
            children: [messageList, overlay]
        )
    }

    /// The tail (last) turn group inside a conversation, for streaming edits.
    private func appendToTailTurn(_ root: inout SnapshotNode, _ node: SnapshotNode) {
        let lastTurn = root.children[0].children.count - 1
        root.children[0].children[lastTurn].children.append(node)
    }

    private func snapshot(root: SnapshotNode, hitNodeID: Int, clickY: CGFloat) -> TargetSnapshot {
        TargetSnapshot(root: root, hitNodeID: hitNodeID, clickPoint: CGPoint(x: 100, y: clickY))
    }

    /// The real-world failure shape: three assistant turns separated by
    /// whitespace, but only the latest turn exposes a Copy button (the source
    /// app shows message controls on hover). Turns are direct children of one
    /// conversation container. Without gap-based segmentation, the single
    /// cluster's range swallowed all three turns.
    private func hoverOnlyConversation() -> SnapshotNode {
        func turn(id: Int, _ a: String, _ b: String, y: CGFloat) -> SnapshotNode {
            SnapshotNode(id: id, role: "AXGroup", frame: CGRect(x: 20, y: y, width: 600, height: 70), children: [
                paragraph(id: id + 1, a, y: y),
                paragraph(id: id + 2, b, y: y + 35),
            ])
        }
        return SnapshotNode(
            id: 1,
            role: "AXGroup",
            identifier: "conversation",
            frame: CGRect(x: 0, y: 80, width: 640, height: 520),
            children: [
                turn(id: 100, "First turn line one", "First turn line two", y: 100),
                turn(id: 200, "Second turn line one", "Second turn line two", y: 260),
                turn(id: 300, "Latest turn line one", "Latest turn line two", y: 420),
                actionRow(id: 400, buttonIDs: [401], y: 500),
            ]
        )
    }

    // MARK: - Boundary selection

    func testLatestResponseExcludesEarlierChatHistory() {
        let fixture = snapshot(root: flatConversation(), hitNodeID: Self.overlayHitID, clickY: 345)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "Second response paragraph\nSecond response continues")
        XCTAssertEqual(resolution?.clusterCount, 3)
    }

    func testOlderResponseIsSelectedByClickLocationNotRecency() {
        let fixture = snapshot(root: flatConversation(), hitNodeID: Self.overlayHitID, clickY: 250)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "First response paragraph\nFirst response continues")
    }

    func testRepeatedIdenticalCopyControlsRemainSeparateBoundaries() {
        let root = flatConversation()
        let clusters = ResponseSelection.actionClusters(in: root, markers: adapter.markers)

        XCTAssertEqual(clusters.count, 3)
    }

    /// Mirrors the real Claude desktop tree: the click lands on a full-height
    /// transparent overlay, message-group and Copy-button frames are collapsed
    /// (height ≤ 1) and mis-positioned, and only the on-screen message has real
    /// leaf frames. Selection must come from structure + the real leaf frames.
    func testVirtualizedTreeSelectsClickedMessageNotWholeConversation() {
        func collapsedCopy(id: Int) -> SnapshotNode {
            SnapshotNode(id: id, role: "AXButton", label: "Copy message",
                         frame: CGRect(x: 237, y: 75, width: 20, height: 1),
                         actionTitles: ["Copy message"])
        }
        // Off-screen-above message: leaves collapsed to y=75, height 1.
        func collapsedMessage(id: Int, _ text: String) -> SnapshotNode {
            SnapshotNode(id: id, role: "AXGroup", frame: CGRect(x: 209, y: 75, width: 655, height: 1), children: [
                SnapshotNode(id: id + 1, role: "AXStaticText", text: text, frame: CGRect(x: 240, y: 75, width: 600, height: 1)),
                collapsedCopy(id: id + 2),
            ])
        }
        // On-screen message: real leaf frames spanning the viewport.
        let visibleMessage = SnapshotNode(id: 517, role: "AXGroup", frame: CGRect(x: 209, y: 75, width: 655, height: 835), children: [
            SnapshotNode(id: 518, role: "AXStaticText", text: "Found it and it explains everything", frame: CGRect(x: 253, y: 206, width: 441, height: 18)),
            SnapshotNode(id: 519, role: "AXStaticText", text: "Two apps were running", frame: CGRect(x: 253, y: 235, width: 441, height: 20)),
            collapsedCopy(id: 520),
        ])
        let messageList = SnapshotNode(id: 105, role: "AXGroup", frame: CGRect(x: 209, y: 75, width: 655, height: 835), children: [
            collapsedMessage(id: 106, "Earlier user prompt"),
            collapsedMessage(id: 337, "Earlier assistant answer"),
            visibleMessage,
        ])
        // The click hits a full-conversation-sized empty overlay, sibling to content.
        let overlay = SnapshotNode(id: 775, role: "AXGroup", frame: CGRect(x: 241, y: 75, width: 583, height: 835))
        let container = SnapshotNode(id: 100, role: "AXGroup", frame: CGRect(x: 209, y: 75, width: 655, height: 835), children: [
            messageList,
            overlay,
        ])
        let root = SnapshotNode(id: 1, role: "AXGroup", frame: CGRect(x: 0, y: 34, width: 865, height: 1083), children: [container])
        let fixture = TargetSnapshot(root: root, hitNodeID: 775, clickPoint: CGPoint(x: 379, y: 221))

        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: ClaudeResponseAdapter())

        // Binds polling to the conversation container (100); the turn text proves
        // the right message (517) was isolated.
        XCTAssertEqual(resolution?.containerID, 100)
        XCTAssertEqual(resolution?.sectionIndex, 2)
        XCTAssertEqual(resolution?.text, "Found it and it explains everything\nTwo apps were running")
        XCTAssertFalse(resolution?.text.contains("Earlier") ?? true)
    }

    func testLatestTurnIsolatedWhenOnlyItHasAControl() {
        // Clicking the latest turn must return only it, even though the single
        // Copy button sits below all three turns.
        let fixture = snapshot(root: hoverOnlyConversation(), hitNodeID: 301, clickY: 430)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "Latest turn line one\nLatest turn line two")
    }

    func testOlderTurnIsolatedWithoutOwnControl() {
        let fixture = snapshot(root: hoverOnlyConversation(), hitNodeID: 201, clickY: 270)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "Second turn line one\nSecond turn line two")
    }

    func testHoverOnlyConversationNeverReturnsAllTurns() {
        let fixture = snapshot(root: hoverOnlyConversation(), hitNodeID: 101, clickY: 110)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "First turn line one\nFirst turn line two")
        XCTAssertFalse(resolution?.text.contains("Second turn") ?? true)
        XCTAssertFalse(resolution?.text.contains("Latest turn") ?? true)
    }

    func testResolutionExposesPrecedingMessageAsPromptContext() {
        let fixture = snapshot(root: flatConversation(), hitNodeID: Self.overlayHitID, clickY: 250)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.promptContext, "User asked a question about builds")
    }

    func testFirstMessageHasNoPromptContext() {
        let fixture = snapshot(root: flatConversation(), hitNodeID: Self.overlayHitID, clickY: 120)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertNil(resolution?.promptContext)
    }

    func testUserPromptIsExcludedFromSelectedResponse() {
        let fixture = snapshot(root: flatConversation(), hitNodeID: Self.overlayHitID, clickY: 210)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertFalse(resolution?.text.contains("User asked") ?? true)
    }

    func testPerMessageContainerIsUsedDirectly() {
        let message = SnapshotNode(
            id: 50,
            role: "AXGroup",
            frame: CGRect(x: 0, y: 300, width: 640, height: 120),
            children: [
                paragraph(id: 51, "Contained response", y: 310),
                actionRow(id: 52, buttonIDs: [53], y: 390),
            ]
        )
        let root = SnapshotNode(
            id: 1,
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 640, height: 800),
            children: [
                paragraph(id: 2, "Earlier chat content", y: 40),
                message,
            ]
        )
        let fixture = snapshot(root: root, hitNodeID: 51, clickY: 320)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.containerID, 50)
        XCTAssertEqual(resolution?.text, "Contained response")
    }

    func testResponseWithListsAndCodeBlocksStaysComplete() {
        let message = SnapshotNode(
            id: 60,
            role: "AXGroup",
            frame: CGRect(x: 0, y: 100, width: 640, height: 260),
            children: [
                SnapshotNode(id: 61, role: "AXHeading", text: "Steps", frame: CGRect(x: 20, y: 110, width: 600, height: 30)),
                paragraph(id: 62, "• First step", y: 150),
                paragraph(id: 63, "• Second step", y: 190),
                SnapshotNode(id: 64, role: "AXGroup", frame: CGRect(x: 20, y: 230, width: 600, height: 80), children: [
                    copyButton(id: 65, label: "Copy code", y: 235),
                    paragraph(id: 66, "let value = compute()", y: 250),
                    paragraph(id: 67, "print(value)", y: 285),
                ]),
                actionRow(id: 68, buttonIDs: [69], y: 330),
            ]
        )
        let fixture = TargetSnapshot(root: message, hitNodeID: 62, clickPoint: CGPoint(x: 100, y: 160))
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(
            resolution?.text,
            "## Steps\n• First step\n• Second step\nlet value = compute()\nprint(value)"
        )
    }

    func testVeryLongSingleResponseIsSelectedWhole() {
        let prompt = SnapshotNode(id: 10, role: "AXGroup", frame: CGRect(x: 20, y: 100, width: 600, height: 60), children: [
            paragraph(id: 11, "Short user prompt", y: 100),
            copyButton(id: 13, label: "Copy message", y: 150),
        ])
        var responseChildren: [SnapshotNode] = []
        var expected: [String] = []
        for index in 0..<120 {
            let text = "Long response paragraph number \(index)"
            expected.append(text)
            responseChildren.append(paragraph(id: 200 + index, text, y: 200 + CGFloat(index) * 35))
        }
        responseChildren.append(copyButton(id: 401, y: 200 + 120 * 35))
        let response = SnapshotNode(id: 20, role: "AXGroup", frame: CGRect(x: 20, y: 200, width: 600, height: 4200), children: responseChildren)
        let messageList = SnapshotNode(id: 5, role: "AXGroup", frame: CGRect(x: 20, y: 80, width: 600, height: 4400), children: [prompt, response])
        let overlay = SnapshotNode(id: Self.overlayHitID, role: "AXGroup", frame: CGRect(x: 20, y: 80, width: 600, height: 4400))
        let root = SnapshotNode(id: 1, role: "AXGroup", frame: CGRect(x: 0, y: 80, width: 640, height: 4400), children: [messageList, overlay])
        let fixture = snapshot(root: root, hitNodeID: Self.overlayHitID, clickY: 200 + 60 * 35 + 10)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, expected.joined(separator: "\n"))
    }

    func testAmbiguousBoundaryFailsInsteadOfReturningConversation() {
        var root = flatConversation()
        func stripButtons(_ node: inout SnapshotNode) {
            node.children.removeAll { $0.role == "AXButton" }
            for index in node.children.indices {
                stripButtons(&node.children[index])
            }
        }
        stripButtons(&root)

        let fixture = snapshot(root: root, hitNodeID: Self.overlayHitID, clickY: 345)
        XCTAssertNil(ResponseSelection.resolve(snapshot: fixture, adapter: adapter))
    }

    // MARK: - Streaming

    func testClickOnStreamingLatestResponseSelectsTrailingSection() {
        let fixture = snapshot(root: flatConversation(streamingTail: "Streaming answer begins"), hitNodeID: Self.overlayHitID, clickY: 470)
        let resolution = ResponseSelection.resolve(snapshot: fixture, adapter: adapter)

        XCTAssertEqual(resolution?.text, "Streaming answer begins")
        XCTAssertEqual(resolution?.sectionIndex, 3)
    }

    func testRefreshFollowsStreamingGrowthOfSameMessage() {
        let initial = snapshot(root: flatConversation(streamingTail: "Streaming answer begins"), hitNodeID: Self.overlayHitID, clickY: 470)
        let resolution = ResponseSelection.resolve(snapshot: initial, adapter: adapter)
        XCTAssertNotNil(resolution)

        var grown = flatConversation(streamingTail: "Streaming answer begins")
        appendToTailTurn(&grown, paragraph(id: 42, "and keeps going", y: 505))

        let refreshed = ResponseSelection.refresh(
            containerSnapshot: TargetSnapshot(root: grown, hitNodeID: grown.id, clickPoint: .zero),
            adapter: adapter,
            sectionIndex: resolution?.sectionIndex ?? -1,
            previousText: resolution?.text ?? ""
        )

        XCTAssertEqual(refreshed?.text, "Streaming answer begins\nand keeps going")
    }

    func testRefreshDoesNotSwitchToADifferentMessage() {
        let container = flatConversation()
        let refreshed = ResponseSelection.refresh(
            containerSnapshot: TargetSnapshot(root: container, hitNodeID: container.id, clickPoint: .zero),
            adapter: adapter,
            sectionIndex: 1,
            previousText: "A response that no longer exists anywhere in this conversation"
        )

        XCTAssertNil(refreshed)
    }

    func testRefreshKeepsMessageWhenControlsAppearAfterStreaming() {
        // While streaming, the latest message is a trailing section with no
        // cluster. When its action row appears, the same section index now
        // ends at that cluster and the fingerprint still matches.
        let streaming = snapshot(root: flatConversation(streamingTail: "Streaming answer begins"), hitNodeID: Self.overlayHitID, clickY: 470)
        let resolution = ResponseSelection.resolve(snapshot: streaming, adapter: adapter)

        var finished = flatConversation(streamingTail: "Streaming answer begins")
        appendToTailTurn(&finished, copyButton(id: 44, y: 505))

        let refreshed = ResponseSelection.refresh(
            containerSnapshot: TargetSnapshot(root: finished, hitNodeID: finished.id, clickPoint: .zero),
            adapter: adapter,
            sectionIndex: resolution?.sectionIndex ?? -1,
            previousText: resolution?.text ?? ""
        )

        XCTAssertEqual(refreshed?.text, "Streaming answer begins")
    }
}
