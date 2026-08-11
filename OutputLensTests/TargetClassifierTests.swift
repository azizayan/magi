import XCTest
@testable import OutputLens

final class TargetClassifierTests: XCTestCase {
    func testUniversalEditorShortcutRequiresOptionMOnly() {
        XCTAssertTrue(UniversalEditorShortcut.matches(
            charactersIgnoringModifiers: "m",
            modifierFlags: [.option]
        ))
        XCTAssertFalse(UniversalEditorShortcut.matches(
            charactersIgnoringModifiers: "m",
            modifierFlags: [.option, .command]
        ))
        XCTAssertFalse(UniversalEditorShortcut.matches(
            charactersIgnoringModifiers: "n",
            modifierFlags: [.option]
        ))
    }

    func testEditableRoleTakesPriorityOverReadableText() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXStaticText", text: "A previous response"),
            SnapshotNode(id: 3, role: "AXTextArea", text: "draft prompt", isValueSettable: true),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 3, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .editableInput(nodeID: 3))
    }

    func testClickInsideEditableAncestorIsClassifiedAsInput() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXTextArea", isValueSettable: true, children: [
                SnapshotNode(id: 3, role: "AXStaticText", text: "current draft text"),
            ]),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 3, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .editableInput(nodeID: 2))
    }

    func testSettableValueCountsAsEditableEvenWithoutTextRole() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXWebArea", text: "contenteditable draft", isValueSettable: true),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .editableInput(nodeID: 2))
    }

    func testFocusedEditableFallbackRequiresClickInsideItsOwnFrame() {
        let frame = CGRect(x: 200, y: 900, width: 600, height: 120)

        XCTAssertTrue(TargetClassifier.focusedEditableContainsClick(
            role: "AXTextArea",
            isValueSettable: true,
            frame: frame,
            point: CGPoint(x: 450, y: 980)
        ))
        XCTAssertFalse(TargetClassifier.focusedEditableContainsClick(
            role: "AXTextArea",
            isValueSettable: true,
            frame: frame,
            point: CGPoint(x: 450, y: 500)
        ))
        XCTAssertFalse(TargetClassifier.focusedEditableContainsClick(
            role: "AXStaticText",
            isValueSettable: true,
            frame: frame,
            point: CGPoint(x: 450, y: 980)
        ))
    }

    func testVSCodeIntegratedTerminalIsClassifiedAsTerminalInput() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(
                id: 2,
                role: "AXTextField",
                label: "Terminal 1, zsh Run the command: Toggle Screen Reader Accessibility Mode for an optimized screen reader experience",
                isValueSettable: true
            ),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .terminalInput(nodeID: 2))
    }

    func testMixedHostUnlabeledTerminalTextAreaIsClassifiedAsTerminalInput() {
        let root = SnapshotNode(id: 1, role: "AXScrollArea", children: [
            SnapshotNode(id: 2, role: "AXTextArea", text: "terminal screen buffer"),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(
            TargetClassifier.classify(snapshot, recognizesUnlabeledTerminalSurface: true),
            .terminalInput(nodeID: 2)
        )
        XCTAssertEqual(TargetClassifier.classify(snapshot), .editableInput(nodeID: 2))
    }

    func testVSCodeTerminalCanvasFindsSiblingTerminalCaret() {
        let root = SnapshotNode(id: 1, role: "AXWindow", children: [
            SnapshotNode(id: 2, role: "AXGroup", children: [
                SnapshotNode(id: 3, role: "AXGroup", children: [
                    SnapshotNode(
                        id: 4,
                        role: "AXTextField",
                        label: "Terminal 1, codex Run the command: Toggle Screen Reader Accessibility Mode",
                        isValueSettable: true
                    ),
                ]),
                SnapshotNode(id: 5, role: "AXGroup"),
            ]),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 5, clickPoint: .zero)

        XCTAssertEqual(
            TargetClassifier.classify(snapshot, recognizesUnlabeledTerminalSurface: true),
            .terminalInput(nodeID: 4)
        )
        XCTAssertEqual(TargetClassifier.classify(snapshot), .unsupported)
    }

    func testReadableOutputIsClassifiedAsResponse() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXStaticText", text: "Model output paragraph"),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .assistantResponse)
    }

    func testControlOnlyTreeIsUnsupported() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXButton", actionTitles: ["Copy response"]),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .unsupported)
    }

    func testStaticTextIsNeverEditableEvenIfMarkedSettable() {
        let root = SnapshotNode(id: 1, role: "AXGroup", children: [
            SnapshotNode(id: 2, role: "AXStaticText", text: "response text", isValueSettable: true),
        ])
        let snapshot = TargetSnapshot(root: root, hitNodeID: 2, clickPoint: .zero)

        XCTAssertEqual(TargetClassifier.classify(snapshot), .assistantResponse)
    }

    func testWindowFallbackFindsReadableNodeAtClickInsteadOfScrollArea() {
        let root = SnapshotNode(
            id: 1,
            role: "AXWindow",
            frame: CGRect(x: 0, y: 0, width: 800, height: 800),
            children: [
                SnapshotNode(
                    id: 2,
                    role: "AXScrollArea",
                    frame: CGRect(x: 100, y: 100, width: 600, height: 600),
                    children: [
                        SnapshotNode(id: 3, role: "AXStaticText", text: "Earlier response", frame: CGRect(x: 140, y: 160, width: 500, height: 80)),
                        SnapshotNode(id: 4, role: "AXStaticText", text: "Clicked response", frame: CGRect(x: 140, y: 320, width: 500, height: 80)),
                        SnapshotNode(id: 5, role: "AXGroup", frame: CGRect(x: 100, y: 100, width: 600, height: 600)),
                    ]
                ),
            ]
        )

        XCTAssertEqual(root.bestHitNodeID(at: CGPoint(x: 300, y: 350)), 4)
    }
}
