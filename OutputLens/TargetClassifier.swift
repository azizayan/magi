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
    static func classify(
        _ snapshot: TargetSnapshot,
        recognizesUnlabeledTerminalSurface: Bool = false
    ) -> ClickTargetKind {
        let path = snapshot.hitPath
        guard !path.isEmpty else { return .unsupported }

        for node in path.suffix(8).reversed() {
            if isTerminalSurface(
                node,
                recognizesUnlabeledTerminalSurface: recognizesUnlabeledTerminalSurface
            ) {
                return .terminalInput(nodeID: node.id)
            }
            if recognizesUnlabeledTerminalSurface,
               let terminal = terminalSurfaceDescendant(in: node, remainingDepth: 3) {
                return .terminalInput(nodeID: terminal.id)
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

    static func isTerminalSurface(
        _ node: SnapshotNode,
        recognizesUnlabeledTerminalSurface: Bool = false
    ) -> Bool {
        guard editableRoles.contains(node.role) || node.isValueSettable else { return false }
        let label = node.label.lowercased()
        let identifier = node.identifier.lowercased()
        let hasTerminalMarker = label == "terminal"
            || label.hasPrefix("terminal ")
            || label.contains("terminal accessibility")
            || identifier.contains("terminal")
        if hasTerminalMarker { return true }

        return recognizesUnlabeledTerminalSurface
            && node.role == "AXTextArea"
            && !node.isValueSettable
            && label.isEmpty
            && identifier.isEmpty
    }

    /// VS Code places the terminal's labeled AXTextField caret beside the
    /// large canvas that receives the click. Search only the nearest few
    /// levels of clicked ancestors so other Terminal controls elsewhere in the
    /// IDE window cannot turn an editor or sidebar click into terminal input.
    private static func terminalSurfaceDescendant(
        in node: SnapshotNode,
        remainingDepth: Int
    ) -> SnapshotNode? {
        guard remainingDepth > 0 else { return nil }
        for child in node.children {
            if isTerminalSurface(child) { return child }
            if let match = terminalSurfaceDescendant(
                in: child,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }
}
