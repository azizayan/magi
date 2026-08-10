import CoreGraphics
import Foundation

/// A pure-data capture of part of a source application's Accessibility tree.
/// Selection and classification logic operates on this model so it can be
/// exercised with saved fixtures instead of a live application.
struct SnapshotNode: Codable {
    var id: Int
    var role: String
    var identifier: String
    var label: String
    var text: String
    var frame: CGRect?
    var isValueSettable: Bool
    var actionTitles: [String]
    var children: [SnapshotNode]

    init(
        id: Int,
        role: String,
        identifier: String = "",
        label: String = "",
        text: String = "",
        frame: CGRect? = nil,
        isValueSettable: Bool = false,
        actionTitles: [String] = [],
        children: [SnapshotNode] = []
    ) {
        self.id = id
        self.role = role
        self.identifier = identifier
        self.label = label
        self.text = text
        self.frame = frame
        self.isValueSettable = isValueSettable
        self.actionTitles = actionTitles
        self.children = children
    }
}

struct TargetSnapshot: Codable {
    var root: SnapshotNode
    var hitNodeID: Int
    var clickPoint: CGPoint
}

extension SnapshotNode {
    func node(withID target: Int) -> SnapshotNode? {
        if id == target { return self }
        for child in children {
            if let found = child.node(withID: target) { return found }
        }
        return nil
    }

    /// Node IDs from this node down to `target`, inclusive, or nil when absent.
    func path(to target: Int) -> [Int]? {
        if id == target { return [id] }
        for child in children {
            if let rest = child.path(to: target) { return [id] + rest }
        }
        return nil
    }

    func forEachDocumentOrder(_ visit: (SnapshotNode) -> Void) {
        visit(self)
        for child in children {
            child.forEachDocumentOrder(visit)
        }
    }

    func contains(nodeID: Int) -> Bool {
        node(withID: nodeID) != nil
    }

    /// Find the deepest useful node whose frame contains the click. Some
    /// Electron builds return a detached scroll area from system hit-testing;
    /// a focused-window snapshot still exposes the real text descendants.
    func bestHitNodeID(at point: CGPoint) -> Int? {
        var bestMeaningful: (id: Int, depth: Int, area: CGFloat)?
        var bestAny: (id: Int, depth: Int, area: CGFloat)?

        func consider(_ candidate: inout (id: Int, depth: Int, area: CGFloat)?, node: SnapshotNode, depth: Int) {
            let area = max(0, node.frame?.width ?? 0) * max(0, node.frame?.height ?? 0)
            if let current = candidate,
               current.depth > depth || (current.depth == depth && current.area <= area) {
                return
            }
            candidate = (node.id, depth, area)
        }

        func walk(_ node: SnapshotNode, depth: Int) {
            guard node.frame?.contains(point) == true else { return }
            consider(&bestAny, node: node, depth: depth)
            if !node.text.isEmpty || node.isValueSettable || TargetClassifier.editableRoles.contains(node.role) {
                consider(&bestMeaningful, node: node, depth: depth)
            }
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }

        walk(self, depth: 0)
        return bestMeaningful?.id ?? bestAny?.id
    }
}

extension TargetSnapshot {
    var hitNode: SnapshotNode? { root.node(withID: hitNodeID) }

    /// Path of nodes from the root down to the hit node, deepest last.
    var hitPath: [SnapshotNode] {
        guard let ids = root.path(to: hitNodeID) else { return [] }
        return ids.compactMap { root.node(withID: $0) }
    }
}

/// Redaction for debug logging and saved fixtures. Only structural data and
/// recognized response-control categories survive; accessibility strings can
/// contain complete conversations and must never be exported verbatim.
enum SnapshotRedaction {
    private static let safeResponseControls: Set<String> = [
        "bad response", "copy", "copy message", "copy response",
        "edit", "good response", "regenerate", "retry",
    ]

    private static func responseControlCategory(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return safeResponseControls.contains(normalized) ? normalized : nil
    }

    static func redacted(_ node: SnapshotNode) -> SnapshotNode {
        var copy = node
        if !copy.text.isEmpty {
            copy.text = "«redacted chars=\(copy.text.count)»"
        }
        copy.label = responseControlCategory(copy.label) ?? ""
        copy.identifier = ""
        copy.actionTitles = Set(copy.actionTitles.compactMap(responseControlCategory)).sorted()
        copy.children = copy.children.map(redacted)
        return copy
    }

    static func redacted(_ snapshot: TargetSnapshot) -> TargetSnapshot {
        TargetSnapshot(
            root: redacted(snapshot.root),
            hitNodeID: snapshot.hitNodeID,
            clickPoint: snapshot.clickPoint
        )
    }

    static func structuralSummary(_ snapshot: TargetSnapshot) -> String {
        let safeSnapshot = redacted(snapshot)
        var lines: [String] = ["click=\(Int(safeSnapshot.clickPoint.x)),\(Int(safeSnapshot.clickPoint.y)) hit=\(safeSnapshot.hitNodeID)"]
        summarize(safeSnapshot.root, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func summarize(_ node: SnapshotNode, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var parts = ["id=\(node.id)", "role=\(node.role)"]
        if !node.identifier.isEmpty { parts.append("identifier=\(node.identifier)") }
        if !node.label.isEmpty { parts.append("control=\(node.label)") }
        if !node.text.isEmpty { parts.append(node.text) }
        if let frame = node.frame {
            parts.append("frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        if !node.actionTitles.isEmpty { parts.append("actions=\(node.actionTitles.joined(separator: "|"))") }
        if node.isValueSettable { parts.append("settable") }
        lines.append(indent + parts.joined(separator: " "))
        for child in node.children {
            summarize(child, depth: depth + 1, into: &lines)
        }
    }
}
