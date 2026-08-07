import Foundation

enum ClickTargetKind: Equatable {
    case editableInput(nodeID: Int)
    case terminalInput(nodeID: Int)
    case assistantResponse
    case unsupported
}

enum TargetClassifier {
    static let editableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox",
    ]

    private static let neverEditableRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXButton", "AXMenuButton", "AXLink", "AXImage",
    ]

    /// Editable roles and settable values take priority; otherwise a click
    /// inside readable output enters response selection.
    static func classify(_ snapshot: TargetSnapshot) -> ClickTargetKind {
        let path = snapshot.hitPath
        guard !path.isEmpty else { return .unsupported }

        for node in path.suffix(8).reversed() {
            if isTerminalSurface(node) {
                return .terminalInput(nodeID: node.id)
            }
        }

        for node in path.suffix(4).reversed() {
            if isEditable(node) {
                return .editableInput(nodeID: node.id)
            }
        }

        var hasReadableText = false
        snapshot.root.forEachDocumentOrder { node in
            if !node.text.isEmpty, node.role != "AXButton", node.role != "AXMenuButton" {
                hasReadableText = true
            }
        }
        return hasReadableText ? .assistantResponse : .unsupported
    }

    static func isEditable(_ node: SnapshotNode) -> Bool {
        if editableRoles.contains(node.role) { return true }
        return node.isValueSettable && !neverEditableRoles.contains(node.role)
    }

    static func isTerminalSurface(_ node: SnapshotNode) -> Bool {
        guard editableRoles.contains(node.role) || node.isValueSettable else { return false }
        let label = node.label.lowercased()
        let identifier = node.identifier.lowercased()
        return label == "terminal"
            || label.hasPrefix("terminal ")
            || label.contains("terminal accessibility")
            || identifier.contains("terminal")
    }
}
