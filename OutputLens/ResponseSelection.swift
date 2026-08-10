import CoreGraphics
import Foundation

/// Control labels an adapter treats as message-boundary evidence.
struct ResponseControlMarkers {
    /// Lowercased labels marking a message-action control. Exact match or
    /// substring containment both count.
    let boundaryMarkers: [String]
    /// Lowercased labels that must never count, such as per-code-block copy
    /// buttons inside a response.
    let excludedMarkers: [String]

    func matches(_ actionTitles: [String]) -> Bool {
        actionTitles.contains { title in
            let normalized = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excludedMarkers.contains(where: { normalized.contains($0) }) else { return false }
            return boundaryMarkers.contains { marker in
                normalized == marker || normalized.contains(marker)
            }
        }
    }
}

/// One supported source application. Adapters share the traversal and
/// partitioning code and differ only in the structural evidence they trust,
/// because Codex and Claude expose different Accessibility trees and change
/// them independently.
protocol ResponseAdapter {
    var name: String { get }
    var markers: ResponseControlMarkers { get }
}

struct CodexResponseAdapter: ResponseAdapter {
    let name = "codex"
    let markers = ResponseControlMarkers(
        boundaryMarkers: [
            "copy response", "copy message", "copy", "good response", "bad response",
            "thumbs up", "thumbs down", "show message actions", "edit message",
        ],
        excludedMarkers: ["copy code", "copy link", "copy path", "copy command"]
    )
}

struct ClaudeResponseAdapter: ResponseAdapter {
    let name = "claude"
    let markers = ResponseControlMarkers(
        boundaryMarkers: [
            "copy response", "copy message", "copy", "good response", "bad response",
            "thumbs up", "thumbs down", "show message actions", "retry", "edit message",
        ],
        excludedMarkers: ["copy code", "copy link", "copy path", "copy command"]
    )
}

/// A row of message-action controls found in the tree. Each cluster is
/// structural evidence for one message boundary; repeated clusters are never
/// collapsed into one.
struct ActionCluster {
    let buttonIDs: [Int]
    let frame: CGRect
}

struct MessageSection {
    /// Stable index in document order. Cluster rows are only appended at the
    /// bottom of a conversation, so the index survives streaming refreshes.
    let index: Int
    let yRange: ClosedRange<CGFloat>
    let fragments: [ResponseTextFragment]
    var text: String { ResponseHeuristics.assemble(fragments) }

    var frame: CGRect? {
        let frames = fragments.compactMap(\.frame)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}

struct ResponseResolution {
    let adapterName: String
    let containerID: Int
    let sectionIndex: Int
    let clusterCount: Int
    let text: String
    let frame: CGRect?
    /// Text of the message immediately preceding the selected one — usually
    /// the user prompt that produced it. Optional context, shown only when the
    /// reader's prompt header is enabled.
    let promptContext: String?
}

enum ResponseSelection {
    /// Resolve the single assistant message containing the click, or nil when
    /// the boundary cannot be identified confidently. There is deliberately no
    /// whole-conversation fallback: a wrong small answer is recoverable, a
    /// whole-chat answer is the reported bug.
    static func resolve(snapshot: TargetSnapshot, adapter: ResponseAdapter) -> ResponseResolution? {
        let path = snapshot.hitPath
        guard !path.isEmpty else { return nil }

        guard let container = selectContainer(path: path, markers: adapter.markers) else { return nil }
        let clusters = actionClusters(in: container, markers: adapter.markers)
        guard !clusters.isEmpty else { return nil }

        // Primary path: structural per-message selection. Desktop apps like
        // Claude virtualize their Accessibility tree — only the on-screen
        // message has real leaf frames, and control buttons carry degenerate
        // (zero-height, mis-positioned) frames — so geometry alone fails. But
        // the tree still groups each turn under a message-list node, so we map
        // the click to its real-framed leaf and take the owning turn.
        if let structural = structuralResolution(container: container, adapter: adapter, clickPoint: snapshot.clickPoint) {
            return structural
        }

        // Fallback for trees without per-message controls: geometry segments.
        let sections = segments(container: container, clusters: clusters, markers: adapter.markers)
        guard let section = selectedSection(
            sections,
            clickY: snapshot.clickPoint.y,
            hitNode: snapshot.hitNode
        ) else { return nil }

        let text = section.text
        guard !text.isEmpty else { return nil }

        return ResponseResolution(
            adapterName: adapter.name,
            containerID: container.id,
            sectionIndex: section.index,
            clusterCount: clusters.count,
            text: text,
            frame: section.frame,
            promptContext: precedingSectionText(sections, before: section.index)
        )
    }

    /// Re-resolve a previously selected message during streaming. Identity is
    /// the stable section index verified by the text fingerprint; when the
    /// index no longer matches, the other sections are checked before giving
    /// up. Returns nil when the same message can no longer be identified.
    static func refresh(
        containerSnapshot: TargetSnapshot,
        adapter: ResponseAdapter,
        sectionIndex: Int,
        previousText: String
    ) -> ResponseResolution? {
        let container = containerSnapshot.root
        let clusters = actionClusters(in: container, markers: adapter.markers)
        guard !clusters.isEmpty else { return nil }

        // Prefer structural identity: re-pick the same turn index, confirmed by
        // the text fingerprint, so streaming growth stays on one message.
        if let turns = messageTurns(container: container, markers: adapter.markers) {
            let order = [sectionIndex] + turns.indices.filter { $0 != sectionIndex }
            for index in order where turns.indices.contains(index) {
                let text = ResponseHeuristics.assemble(textFragments(in: turns[index], markers: adapter.markers))
                guard !text.isEmpty, ResponseHeuristics.isSafeUpdate(previous: previousText, next: text) else { continue }
                return ResponseResolution(
                    adapterName: adapter.name,
                    containerID: turns[index].id,
                    sectionIndex: index,
                    clusterCount: turns.count,
                    text: text,
                    frame: unionFrame(textFragments(in: turns[index], markers: adapter.markers)),
                    promptContext: precedingTurnText(turns, before: index, markers: adapter.markers)
                )
            }
            return nil
        }

        let sections = segments(container: container, clusters: clusters, markers: adapter.markers)

        let candidates = sections.filter { $0.index == sectionIndex } + sections.filter { $0.index != sectionIndex }
        for section in candidates {
            let text = section.text
            guard !text.isEmpty, ResponseHeuristics.isSafeUpdate(previous: previousText, next: text) else { continue }
            return ResponseResolution(
                adapterName: adapter.name,
                containerID: container.id,
                sectionIndex: section.index,
                clusterCount: clusters.count,
                text: text,
                frame: section.frame,
                promptContext: precedingSectionText(sections, before: section.index)
            )
        }
        return nil
    }

    private static func precedingSectionText(_ sections: [MessageSection], before index: Int) -> String? {
        guard let previous = sections.first(where: { $0.index == index - 1 }) else { return nil }
        let text = previous.text
        return text.isEmpty ? nil : text
    }

    // MARK: - Structural per-message selection

    /// Minimum height for a leaf frame to count as really laid out rather than
    /// a virtualized/collapsed placeholder.
    private static let realFrameHeight: CGFloat = 6

    /// Resolve the single turn the click lands in by structure: map the click
    /// to the nearest real-framed text leaf, then take the message-list child
    /// that owns it. Returns nil when the tree has no per-message grouping, so
    /// the caller can fall back to geometry.
    static func structuralResolution(
        container: SnapshotNode,
        adapter: ResponseAdapter,
        clickPoint: CGPoint
    ) -> ResponseResolution? {
        guard let turns = messageTurns(container: container, markers: adapter.markers) else { return nil }

        let selectedIndex: Int
        if let verticallyContaining = turns.firstIndex(where: { turn in
            guard let frame = turn.frame, frame.height >= realFrameHeight else { return false }
            return frame.minY...frame.maxY ~= clickPoint.y
        }) {
            // Message groups span the complete visual turn. Ignore horizontal
            // position so margins, indentation, code-block padding, and empty
            // space within that turn all behave like clicking its text.
            selectedIndex = verticallyContaining
        } else {
            let leaves = realFramedLeaves(in: container)
            guard !leaves.isEmpty else { return nil }

            let clicked: SnapshotNode
            if let containing = leaves
                .filter({ $0.frame?.contains(clickPoint) == true })
                .min(by: { ($0.frame?.height ?? .greatestFiniteMagnitude) < ($1.frame?.height ?? .greatestFiniteMagnitude) }) {
                clicked = containing
            } else if let nearest = leaves.min(by: {
                abs(($0.frame?.midY ?? 0) - clickPoint.y) < abs(($1.frame?.midY ?? 0) - clickPoint.y)
            }) {
                clicked = nearest
            } else {
                return nil
            }

            guard let leafTurnIndex = turns.firstIndex(where: { $0.node(withID: clicked.id) != nil }) else { return nil }
            selectedIndex = leafTurnIndex
        }
        let fragments = textFragments(in: turns[selectedIndex], markers: adapter.markers)
        let text = ResponseHeuristics.assemble(fragments)
        guard !text.isEmpty else { return nil }

        // Bind polling to the conversation container, not the turn: streaming
        // re-resolves the same turn index inside it each tick. The turn's own
        // text and frame are carried on the resolution for the initial render.
        return ResponseResolution(
            adapterName: adapter.name,
            containerID: container.id,
            sectionIndex: selectedIndex,
            clusterCount: turns.count,
            text: text,
            frame: unionFrame(fragments),
            promptContext: precedingTurnText(turns, before: selectedIndex, markers: adapter.markers)
        )
    }

    /// The children of the message-list node — one per conversation turn.
    /// Derived from the message-action controls: each control's highest
    /// single-control ancestor is one message; those messages share the
    /// message-list parent. nil when no such grouping exists.
    static func messageTurns(container: SnapshotNode, markers: ResponseControlMarkers) -> [SnapshotNode]? {
        let parent = parentMap(container)
        var byID: [Int: SnapshotNode] = [:]
        container.forEachDocumentOrder { byID[$0.id] = $0 }

        let controlButtons = byID.values.filter { isControlButton($0, markers: markers) }
        guard !controlButtons.isEmpty else { return nil }

        var messageIDs: [Int] = []
        var seen: Set<Int> = []
        for button in controlButtons {
            var messageID = button.id
            var ancestor = parent[button.id]
            while let id = ancestor, let node = byID[id], controlButtonCount(node, markers: markers) == 1 {
                messageID = id
                ancestor = parent[id]
            }
            if seen.insert(messageID).inserted { messageIDs.append(messageID) }
        }

        // A flat Chromium tree can place response controls and individual text
        // fragments directly under the same parent. In that shape the button
        // itself is not a message turn; treating every sibling as one turn is
        // what reduced a click to a single sentence.
        guard messageIDs.allSatisfy({ id in
            guard let node = byID[id] else { return false }
            return !isControlButton(node, markers: markers)
        }) else { return nil }

        var parentCounts: [Int: Int] = [:]
        for id in messageIDs {
            if let listID = parent[id] { parentCounts[listID, default: 0] += 1 }
        }
        guard let listID = parentCounts.max(by: { $0.value < $1.value })?.key,
              let listNode = byID[listID], listNode.children.count >= 2 else { return nil }
        return listNode.children
    }

    private static func realFramedLeaves(in container: SnapshotNode) -> [SnapshotNode] {
        var leaves: [SnapshotNode] = []
        container.forEachDocumentOrder { node in
            guard !node.text.isEmpty, node.role != "AXButton", node.role != "AXMenuButton" else { return }
            if let height = node.frame?.height, height >= realFrameHeight {
                leaves.append(node)
            }
        }
        return leaves
    }

    private static func controlButtonCount(_ node: SnapshotNode, markers: ResponseControlMarkers) -> Int {
        var count = isControlButton(node, markers: markers) ? 1 : 0
        for child in node.children {
            count += controlButtonCount(child, markers: markers)
        }
        return count
    }

    private static func parentMap(_ root: SnapshotNode) -> [Int: Int] {
        var parent: [Int: Int] = [:]
        func walk(_ node: SnapshotNode) {
            for child in node.children {
                parent[child.id] = node.id
                walk(child)
            }
        }
        walk(root)
        return parent
    }

    private static func precedingTurnText(_ turns: [SnapshotNode], before index: Int, markers: ResponseControlMarkers) -> String? {
        guard index > 0 else { return nil }
        let text = ResponseHeuristics.assemble(textFragments(in: turns[index - 1], markers: markers))
        return text.isEmpty ? nil : text
    }

    private static func unionFrame(_ fragments: [ResponseTextFragment]) -> CGRect? {
        let frames = fragments.compactMap(\.frame)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Container selection

    /// The deepest ancestor of the hit node that contains at least one
    /// complete action cluster. A per-message container (one cluster) is used
    /// directly; a conversation container (several clusters) is partitioned.
    private static func selectContainer(path: [SnapshotNode], markers: ResponseControlMarkers) -> SnapshotNode? {
        for ancestor in path.reversed() {
            if !actionClusters(in: ancestor, markers: markers).isEmpty {
                return ancestor
            }
        }
        return nil
    }

    // MARK: - Clusters

    static func actionClusters(in container: SnapshotNode, markers: ResponseControlMarkers) -> [ActionCluster] {
        struct ControlButton {
            let id: Int
            let parentID: Int
            let frame: CGRect?
        }

        var buttons: [ControlButton] = []
        func walk(_ node: SnapshotNode, parentID: Int) {
            if isControlButton(node, markers: markers) {
                buttons.append(ControlButton(id: node.id, parentID: parentID, frame: node.frame))
                return
            }
            for child in node.children {
                walk(child, parentID: node.id)
            }
        }
        walk(container, parentID: container.id)
        guard !buttons.isEmpty else { return [] }

        // Buttons in one action row share a parent, but a flat tree can put
        // every message's buttons under the same parent. Group by parent, then
        // split each group into vertical runs so repeated identical controls
        // stay separate structural evidence rather than one merged cluster.
        var groups: [[ControlButton]] = []
        var parentIndex: [Int: Int] = [:]
        for button in buttons {
            if let index = parentIndex[button.parentID] {
                groups[index].append(button)
            } else {
                parentIndex[button.parentID] = groups.count
                groups.append([button])
            }
        }

        var runs: [[ControlButton]] = []
        for group in groups {
            let framed = group.filter { $0.frame != nil }.sorted { $0.frame!.midY < $1.frame!.midY }
            let frameless = group.filter { $0.frame == nil }
            var current: [ControlButton] = []
            for button in framed {
                if let lastFrame = current.last?.frame, let frame = button.frame,
                   frame.midY - lastFrame.midY > max(40, lastFrame.height * 1.5) {
                    runs.append(current)
                    current = []
                }
                current.append(button)
            }
            if !current.isEmpty { runs.append(current) }
            if !frameless.isEmpty { runs.append(frameless) }
        }

        var clusters: [ActionCluster] = runs.map { run in
            let frames = run.compactMap(\.frame)
            guard let first = frames.first else {
                return ActionCluster(buttonIDs: run.map(\.id), frame: .null)
            }
            let union = frames.dropFirst().reduce(first) { $0.union($1) }
            return ActionCluster(buttonIDs: run.map(\.id), frame: union)
        }

        clusters.sort { first, second in
            switch (first.frame.isNull, second.frame.isNull) {
            case (false, false): first.frame.midY < second.frame.midY
            case (false, true): true
            default: false
            }
        }
        var merged: [ActionCluster] = []
        for cluster in clusters {
            if let last = merged.last, !last.frame.isNull, !cluster.frame.isNull,
               abs(cluster.frame.midY - last.frame.midY) <= max(24, min(last.frame.height, cluster.frame.height)) {
                merged[merged.count - 1] = ActionCluster(
                    buttonIDs: last.buttonIDs + cluster.buttonIDs,
                    frame: last.frame.union(cluster.frame)
                )
            } else {
                merged.append(cluster)
            }
        }
        return merged
    }

    static func isControlButton(_ node: SnapshotNode, markers: ResponseControlMarkers) -> Bool {
        guard node.role == "AXButton" || node.role == "AXMenuButton" else { return false }
        var titles = node.actionTitles
        if !node.label.isEmpty { titles.append(node.label) }
        if !node.identifier.isEmpty { titles.append(node.identifier) }
        return markers.matches(titles)
    }

    // MARK: - Segmentation

    /// Split a container into vertically contiguous message sections.
    ///
    /// A boundary is drawn at every action-cluster bottom (a message ends at
    /// its own controls) AND at every large vertical gap between text (the
    /// whitespace that separates one turn from the next). Relying on gaps as
    /// well as controls is what makes selection correct even when the source
    /// app exposes an action button only for the hovered/latest message — the
    /// previous failure mode where the first range swallowed several messages.
    ///
    /// Each text fragment is assigned to exactly one section, so a section can
    /// never contain another message's text. There is deliberately no
    /// whole-container fallback: if no boundaries are found the container is a
    /// single message and is returned whole; if boundaries exist, one turn is
    /// isolated.
    static func segments(
        container: SnapshotNode,
        clusters: [ActionCluster],
        markers: ResponseControlMarkers
    ) -> [MessageSection] {
        let fragments = textFragments(in: container, markers: markers)
        let fragmentFrames = fragments.compactMap(\.frame)

        let clusterBottoms = clusters.filter { !$0.frame.isNull }.map(\.frame.maxY)
        // Multiple real action rows already provide exact message endings.
        // Adding whitespace boundaries in that shape incorrectly splits long
        // Codex answers at lists, callouts, and paragraph gaps. Whitespace is
        // only evidence when the source exposes at most one real action row
        // (for example, hover-only controls).
        let gapBoundaries = clusterBottoms.count <= 1 ? turnGapBoundaries(fragments) : []

        let fragmentTop = fragmentFrames.map(\.minY).min()
        let fragmentBottom = fragmentFrames.map(\.maxY).max()
        let top = min(container.frame?.minY ?? fragmentTop ?? 0, fragmentTop ?? .greatestFiniteMagnitude)
        let bottom = max(container.frame?.maxY ?? fragmentBottom ?? 0, fragmentBottom ?? -.greatestFiniteMagnitude)

        // Interior boundaries (strictly inside the container), sorted and deduped.
        var interior = (clusterBottoms + gapBoundaries)
            .filter { $0 > top + 1 && $0 < bottom - 1 }
            .sorted()
        interior = dedupe(interior, tolerance: 2)

        let bounds = [top] + interior + [bottom]
        let rangeCount = max(1, bounds.count - 1)

        var buckets: [[ResponseTextFragment]] = Array(repeating: [], count: rangeCount)
        for fragment in fragments {
            let index = segmentIndex(for: fragment.frame?.midY, in: bounds)
            buckets[min(index, rangeCount - 1)].append(fragment)
        }

        return buckets.enumerated().map { index, sectionFragments in
            let lower = bounds[index]
            let upper = bounds[min(index + 1, bounds.count - 1)]
            return MessageSection(index: index, yRange: lower...max(lower, upper), fragments: sectionFragments)
        }
    }

    /// Y positions where a vertical whitespace gap is large enough to be a turn
    /// separator rather than ordinary paragraph spacing.
    static func turnGapBoundaries(_ fragments: [ResponseTextFragment]) -> [CGFloat] {
        // Virtualized Chromium trees retain offscreen nodes with zero-height
        // frames. Including those collapses the median and makes ordinary
        // paragraph spacing look like a turn boundary.
        let framed = fragments.compactMap(\.frame)
            .filter { $0.height >= realFrameHeight }
            .sorted { $0.minY < $1.minY }
        guard framed.count >= 2 else { return [] }

        let medianHeight = median(framed.map(\.height)) ?? 16
        let threshold = max(medianHeight * 1.2, 14)

        var boundaries: [CGFloat] = []
        for (previous, next) in zip(framed, framed.dropFirst()) {
            let gap = next.minY - previous.maxY
            if gap > threshold {
                boundaries.append((previous.maxY + next.minY) / 2)
            }
        }
        return boundaries
    }

    /// Index of the segment a Y coordinate falls into: the number of interior
    /// bounds at or below it. Content above the first bound goes to segment 0.
    private static func segmentIndex(for y: CGFloat?, in bounds: [CGFloat]) -> Int {
        guard let y else { return 0 }
        var index = 0
        for bound in bounds.dropFirst().dropLast() where bound <= y {
            index += 1
        }
        return index
    }

    private static func dedupe(_ values: [CGFloat], tolerance: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values {
            if let last = result.last, abs(value - last) <= tolerance { continue }
            result.append(value)
        }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func textFragments(in container: SnapshotNode, markers: ResponseControlMarkers) -> [ResponseTextFragment] {
        var fragments: [ResponseTextFragment] = []
        func walk(_ node: SnapshotNode) {
            if isControlButton(node, markers: markers) { return }
            if !node.text.isEmpty, node.role != "AXButton", node.role != "AXMenuButton" {
                fragments.append(ResponseTextFragment(text: node.text, frame: node.frame, role: node.role))
                return
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(container)
        return fragments
    }

    private static func selectedSection(
        _ sections: [MessageSection],
        clickY: CGFloat,
        hitNode: SnapshotNode?
    ) -> MessageSection? {
        let nonEmpty = sections.filter { !$0.fragments.isEmpty }
        if let byClick = nonEmpty.first(where: { $0.yRange.contains(clickY) }) {
            return byClick
        }
        if let hitY = hitNode?.frame?.midY,
           let byHit = nonEmpty.first(where: { $0.yRange.contains(hitY) }) {
            return byHit
        }
        return nil
    }
}
