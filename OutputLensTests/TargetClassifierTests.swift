import XCTest
@testable import OutputLens

final class TargetClassifierTests: XCTestCase {
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
}
