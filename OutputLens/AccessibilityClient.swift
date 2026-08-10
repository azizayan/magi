import AppKit
import ApplicationServices
import Darwin
import OSLog

struct ResponseSnapshot {
    let applicationPID: pid_t
    let containerElement: AXUIElement
    let windowElement: AXUIElement
    let adapter: any ResponseAdapter
    let sectionIndex: Int
    let text: String
    let promptContext: String?
    let responseFrame: CGRect
    let windowFrame: CGRect
}

enum ResolvedTarget {
    case response(ResponseSnapshot)
    case editor(EditorSource)
}

enum AccessibilityClientError: LocalizedError {
    case noElement
    case unsupportedApplication
    case noReadableResponse
    case responseBoundaryNotIdentified
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noElement:
            "Magi could not find anything at that point."
        case .unsupportedApplication:
            "Option-click inside Codex, Claude, or a supported terminal app."
        case .noReadableResponse:
            "That item does not expose readable content. Try clicking directly on its text."
        case .responseBoundaryNotIdentified:
            "Magi could not confidently identify which response was clicked, so the previous content is unchanged."
        case .noWindow:
            "Magi could not identify the source window."
        }
    }
}

final class AccessibilityClient {
    private let chromiumBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.vscodium",
        "com.codeium.windsurf",
        "com.google.antigravity",
    ]
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let logger = Logger(subsystem: "com.azizemreayan.OutputLens", category: "TargetSelection")
    private var preparedApplicationPIDs: Set<pid_t> = []

    /// Elements backing the most recent snapshot, keyed by node ID.
    private var elementsByNodeID: [Int: AXUIElement] = [:]
    private(set) var lastRedactedSnapshot: TargetSnapshot?

    // MARK: - Target resolution

    func target(at point: CGPoint) throws -> ResolvedTarget {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success,
              let hitElement else {
            logger.error("System hit test failed at \(point.x, privacy: .public),\(point.y, privacy: .public)")
            throw AccessibilityClientError.noElement
        }

        var hitPID: pid_t = 0
        AXUIElementGetPid(hitElement, &hitPID)
        guard let owner = SupportedApplication.resolveOwner(
            startingAt: hitPID,
            applicationIdentity: applicationIdentity,
            parentProcessIdentifier: parentProcessIdentifier
        ) else {
            logger.error("Unsupported hit application pid=\(hitPID, privacy: .public)")
            throw AccessibilityClientError.unsupportedApplication
        }
        let pid = owner.processIdentifier
        let bundleIdentifier = owner.bundleIdentifier
        let applicationName = owner.name
        if hitPID != pid {
            logger.notice("Resolved helper pid=\(hitPID, privacy: .public) to owner pid=\(pid, privacy: .public) bundle=\(bundleIdentifier, privacy: .public)")
        }

        // Chromium-based apps do not necessarily expose their web-content
        // Accessibility tree until an assistive app requests it. Re-hit-test
        // so we do not keep the detached placeholder returned beforehand.
        let resolvedHitElement: AXUIElement
        if chromiumBundleIdentifiers.contains(bundleIdentifier) {
            prepareApplicationAccessibility(applicationPID: pid, bundleIdentifier: bundleIdentifier)
            var refreshedElement: AXUIElement?
            if AXUIElementCopyElementAtPosition(
                systemWideElement,
                Float(point.x),
                Float(point.y),
                &refreshedElement
            ) == .success, let refreshedElement {
                resolvedHitElement = refreshedElement
            } else {
                resolvedHitElement = hitElement
            }
        } else {
            resolvedHitElement = hitElement
        }

        if SupportedApplication.isTerminal(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        ) {
            return .editor(try terminalEditorSource(
                hitElement: resolvedHitElement,
                applicationPID: pid,
                applicationName: applicationName,
                prefersFocusedElement: true
            ))
        }

        // Chromium composers often hit-test to a nested text/group node even
        // though the editable AXTextArea is one of its parents. Resolve that
        // live ancestor before building the much larger response snapshot so
        // input clicks cannot fall through to Reader mode.
        if SupportedApplication.desktopBundleIdentifiers.contains(bundleIdentifier),
           let editableElement = nearestEditableAncestor(from: resolvedHitElement) {
            return .editor(try editorSource(
                element: editableElement,
                applicationPID: pid,
                applicationName: applicationName
            ))
        }

        guard var snapshot = captureSnapshot(from: resolvedHitElement, clickPoint: point) else {
            throw AccessibilityClientError.noReadableResponse
        }
        let recognizesUnlabeledTerminalSurface = SupportedApplication.isMixedHost(
            bundleIdentifier: bundleIdentifier
        )
        var targetKind = TargetClassifier.classify(
            snapshot,
            recognizesUnlabeledTerminalSurface: recognizesUnlabeledTerminalSurface
        )
        if targetKind == .unsupported,
           let windowSnapshot = captureFocusedWindowSnapshot(applicationPID: pid, clickPoint: point) {
            snapshot = windowSnapshot
            targetKind = TargetClassifier.classify(
                snapshot,
                recognizesUnlabeledTerminalSurface: recognizesUnlabeledTerminalSurface
            )
        }
        lastRedactedSnapshot = SnapshotRedaction.redacted(snapshot)
        #if DEBUG
        logger.notice("Snapshot:\n\(SnapshotRedaction.structuralSummary(self.lastRedactedSnapshot ?? snapshot), privacy: .public)")
        autoSaveFixture(lastRedactedSnapshot!)
        #endif

        switch targetKind {
        case .terminalInput(let nodeID):
            guard let element = elementsByNodeID[nodeID] else {
                throw AccessibilityClientError.noElement
            }
            return .editor(try terminalEditorSource(
                hitElement: element,
                applicationPID: pid,
                applicationName: applicationName,
                prefersFocusedElement: false
            ))
        case .editableInput(let nodeID):
            guard !SupportedApplication.isMixedHost(bundleIdentifier: bundleIdentifier) else {
                throw AccessibilityClientError.noReadableResponse
            }
            return .editor(try editorSource(
                nodeID: nodeID,
                applicationPID: pid,
                applicationName: applicationName
            ))
        case .assistantResponse:
            guard SupportedApplication.desktopBundleIdentifiers.contains(bundleIdentifier) else {
                throw AccessibilityClientError.noReadableResponse
            }
            return .response(try responseSnapshot(
                snapshot,
                adapter: adapter(for: bundleIdentifier),
                applicationPID: pid
            ))
        case .unsupported:
            throw AccessibilityClientError.noReadableResponse
        }
    }

    /// Open the safe paste-based editor for the frontmost application without
    /// trying to identify a terminal widget. Terminal emulators and terminal
    /// panes do not expose a standard input field, so an explicit keyboard
    /// shortcut is the universal fallback for unknown hosts and CLI tools.
    func frontmostTerminalEditorSource() throws -> EditorSource {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AccessibilityClientError.unsupportedApplication
        }

        let pid = application.processIdentifier
        let applicationElement = AXUIElementCreateApplication(pid)
        let focusedElement: AXUIElement? = copyAttribute(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString
        )
        let focusedWindow: AXUIElement? = copyAttribute(
            applicationElement,
            kAXFocusedWindowAttribute as CFString
        )
        guard let sourceElement = focusedElement ?? focusedWindow else {
            throw AccessibilityClientError.noElement
        }

        return try terminalEditorSource(
            hitElement: sourceElement,
            applicationPID: pid,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "Terminal",
            prefersFocusedElement: true
        )
    }

    private func adapter(for bundleIdentifier: String) -> any ResponseAdapter {
        bundleIdentifier == "com.anthropic.claudefordesktop" ? ClaudeResponseAdapter() : CodexResponseAdapter()
    }

    private func applicationIdentity(processIdentifier: pid_t) -> ApplicationIdentity? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = application.bundleIdentifier else { return nil }
        return ApplicationIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            name: application.localizedName ?? bundleIdentifier
        )
    }

    private func parentProcessIdentifier(_ processIdentifier: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        return size > 0 ? pid_t(info.pbi_ppid) : 0
    }

    func prepareApplicationAccessibility(applicationPID: pid_t, bundleIdentifier: String) {
        guard chromiumBundleIdentifiers.contains(bundleIdentifier),
              preparedApplicationPIDs.insert(applicationPID).inserted else { return }

        let application = AXUIElementCreateApplication(applicationPID)
        // Reading the application role activates Chromium's native AX mode.
        let _: String? = copyAttribute(application, kAXRoleAttribute as CFString)

        guard bundleIdentifier == "com.anthropic.claudefordesktop" else { return }

        let manualResult = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        if manualResult != .success {
            logger.error("Electron accessibility activation failed code=\(manualResult.rawValue, privacy: .public)")
        }
    }

    private func responseSnapshot(
        _ snapshot: TargetSnapshot,
        adapter: any ResponseAdapter,
        applicationPID: pid_t
    ) throws -> ResponseSnapshot {
        guard let resolution = ResponseSelection.resolve(snapshot: snapshot, adapter: adapter) else {
            throw AccessibilityClientError.responseBoundaryNotIdentified
        }
        guard let containerElement = elementsByNodeID[resolution.containerID] else {
            throw AccessibilityClientError.responseBoundaryNotIdentified
        }
        guard let window: AXUIElement = copyAttribute(containerElement, kAXWindowAttribute as CFString),
              let windowFrame = frame(of: window) else {
            throw AccessibilityClientError.noWindow
        }

        logger.notice("Selected adapter=\(resolution.adapterName, privacy: .public) section=\(resolution.sectionIndex) of clusters=\(resolution.clusterCount) chars=\(resolution.text.count) fp=\(SnapshotRedaction.fingerprint(resolution.text), privacy: .public)")

        return ResponseSnapshot(
            applicationPID: applicationPID,
            containerElement: containerElement,
            windowElement: window,
            adapter: adapter,
            sectionIndex: resolution.sectionIndex,
            text: resolution.text,
            promptContext: resolution.promptContext,
            responseFrame: resolution.frame ?? windowFrame,
            windowFrame: windowFrame
        )
    }

    private func editorSource(
        nodeID: Int,
        applicationPID: pid_t,
        applicationName: String
    ) throws -> EditorSource {
        guard let element = elementsByNodeID[nodeID] else {
            throw AccessibilityClientError.noElement
        }
        return try editorSource(
            element: element,
            applicationPID: applicationPID,
            applicationName: applicationName
        )
    }

    private func editorSource(
        element: AXUIElement,
        applicationPID: pid_t,
        applicationName: String
    ) throws -> EditorSource {
        guard let window: AXUIElement = copyAttribute(element, kAXWindowAttribute as CFString),
              let windowFrame = frame(of: window) else {
            throw AccessibilityClientError.noWindow
        }

        let text: String = copyAttribute(element, kAXValueAttribute as CFString) ?? ""
        let capability: WriteBackCapability = isValueSettable(element) ? .direct : .unavailable
        return EditorSource(
            applicationPID: applicationPID,
            applicationName: applicationName,
            element: element,
            windowElement: window,
            windowFrame: windowFrame,
            capability: capability,
            originalText: text
        )
    }

    /// Terminal accessibility values usually contain the entire screen buffer,
    /// not just the command being edited. Always start from a safe empty draft
    /// and hand it back through an explicit user paste.
    private func terminalEditorSource(
        hitElement: AXUIElement,
        applicationPID: pid_t,
        applicationName: String,
        prefersFocusedElement: Bool
    ) throws -> EditorSource {
        let application = AXUIElementCreateApplication(applicationPID)
        let focusedElement: AXUIElement? = copyAttribute(
            application,
            kAXFocusedUIElementAttribute as CFString
        )
        let sourceElement = prefersFocusedElement ? (focusedElement ?? hitElement) : hitElement
        let focusedWindow: AXUIElement? = focusedElement.flatMap { element in
            copyAttribute(element, kAXWindowAttribute as CFString)
        }
        let sourceWindow: AXUIElement? = copyAttribute(hitElement, kAXWindowAttribute as CFString)
            ?? focusedWindow
            ?? copyAttribute(application, kAXFocusedWindowAttribute as CFString)
        guard let window = sourceWindow,
              let windowFrame = frame(of: window) else {
            throw AccessibilityClientError.noWindow
        }

        return EditorSource(
            applicationPID: applicationPID,
            applicationName: applicationName,
            element: sourceElement,
            windowElement: window,
            windowFrame: windowFrame,
            capability: .pasteRequired,
            originalText: ""
        )
    }

    // MARK: - Streaming refresh

    /// Re-resolve the bound message from a fresh snapshot of the same
    /// container. Returns nil when the message identity cannot be confirmed.
    func refreshResponse(_ snapshot: ResponseSnapshot, previousText: String) -> ResponseResolution? {
        var builder = SnapshotBuilder(hitElement: snapshot.containerElement, budget: 3000)
        guard let root = build(snapshot.containerElement, depth: 0, builder: &builder) else { return nil }
        let containerSnapshot = TargetSnapshot(root: root, hitNodeID: root.id, clickPoint: .zero)
        return ResponseSelection.refresh(
            containerSnapshot: containerSnapshot,
            adapter: snapshot.adapter,
            sectionIndex: snapshot.sectionIndex,
            previousText: previousText
        )
    }

    // MARK: - Snapshot capture

    func captureSnapshot(from hitElement: AXUIElement, clickPoint: CGPoint) -> TargetSnapshot? {
        var ancestors: [AXUIElement] = [hitElement]
        var current: AXUIElement? = hitElement
        for _ in 0..<15 {
            guard let node = current,
                  let parent: AXUIElement = copyAttribute(node, kAXParentAttribute as CFString) else { break }
            let role: String = copyAttribute(parent, kAXRoleAttribute as CFString) ?? ""
            if role == (kAXWindowRole as String) || role == "AXApplication" { break }
            ancestors.append(parent)
            current = parent
        }

        // Build from the highest ancestor. A snapshot that merely contains the
        // hit is not enough: if its node budget was exhausted after the hit,
        // the end of a long response may be missing. Narrow progressively
        // until the clicked subtree is captured completely.
        var truncatedFallback: (snapshot: TargetSnapshot, elements: [Int: AXUIElement])?
        for root in ancestors.reversed() {
            var builder = SnapshotBuilder(hitElement: hitElement, budget: 3000)
            guard let rootNode = build(root, depth: 0, builder: &builder) else { continue }
            if let hitID = builder.hitID {
                let snapshot = TargetSnapshot(root: rootNode, hitNodeID: hitID, clickPoint: clickPoint)
                if !builder.wasTruncated {
                    elementsByNodeID = builder.elements
                    return snapshot
                }
                if truncatedFallback == nil {
                    truncatedFallback = (snapshot, builder.elements)
                }
            }
        }
        if let truncatedFallback {
            elementsByNodeID = truncatedFallback.elements
            return truncatedFallback.snapshot
        }
        return nil
    }

    /// Fallback for Electron hit-testing that returns a detached AXScrollArea
    /// with no parent or children. Snapshot the focused window, then derive the
    /// real hit node geometrically from its readable/editable descendants.
    private func captureFocusedWindowSnapshot(applicationPID: pid_t, clickPoint: CGPoint) -> TargetSnapshot? {
        let application = AXUIElementCreateApplication(applicationPID)
        guard let window: AXUIElement = copyAttribute(application, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        var builder = SnapshotBuilder(hitElement: window, budget: 6000)
        guard let root = build(window, depth: 0, builder: &builder),
              let hitNodeID = root.bestHitNodeID(at: clickPoint) else { return nil }
        if builder.wasTruncated,
           let refinedHitElement = builder.elements[hitNodeID],
           let refinedSnapshot = captureSnapshot(from: refinedHitElement, clickPoint: clickPoint) {
            return refinedSnapshot
        }
        elementsByNodeID = builder.elements
        return TargetSnapshot(root: root, hitNodeID: hitNodeID, clickPoint: clickPoint)
    }

    private struct SnapshotBuilder {
        let hitElement: AXUIElement
        var budget: Int
        var nextID = 0
        var elements: [Int: AXUIElement] = [:]
        var hitID: Int?
        var wasTruncated = false
    }

    private func build(_ element: AXUIElement, depth: Int, builder: inout SnapshotBuilder) -> SnapshotNode? {
        guard depth <= 40, builder.budget > 0 else {
            builder.wasTruncated = true
            return nil
        }
        builder.budget -= 1

        let id = builder.nextID
        builder.nextID += 1
        builder.elements[id] = element
        if CFEqual(element, builder.hitElement) {
            builder.hitID = id
        }

        let role: String = copyAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
        let identifier: String = copyAttribute(element, kAXIdentifierAttribute as CFString) ?? ""
        let label: String = copyAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let isButton = role == (kAXButtonRole as String) || role == "AXMenuButton"
        let text: String = isButton ? "" : (copyAttribute(element, kAXValueAttribute as CFString) ?? "")

        var actionTitles: [String] = []
        if isButton {
            let values: [String?] = [
                copyAttribute(element, kAXTitleAttribute as CFString),
                label.isEmpty ? nil : label,
                copyAttribute(element, kAXHelpAttribute as CFString),
                identifier.isEmpty ? nil : identifier,
            ]
            actionTitles = values.compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        let settable = TargetClassifier.editableRoles.contains(role) && isValueSettable(element)

        var childNodes: [SnapshotNode] = []
        for child in children(of: element) {
            guard builder.budget > 0 else {
                builder.wasTruncated = true
                break
            }
            if let childNode = build(child, depth: depth + 1, builder: &builder) {
                childNodes.append(childNode)
            }
        }

        return SnapshotNode(
            id: id,
            role: role,
            identifier: identifier,
            label: label,
            text: ResponseHeuristics.normalizeLineEndings(text),
            frame: frame(of: element),
            isValueSettable: settable,
            actionTitles: actionTitles,
            children: childNodes
        )
    }

    // MARK: - Element helpers

    private func nearestEditableAncestor(from hitElement: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = hitElement
        for _ in 0..<16 {
            guard let element = current else { return nil }
            let role: String = copyAttribute(element, kAXRoleAttribute as CFString) ?? ""
            if TargetClassifier.editableRoles.contains(role), isValueSettable(element) {
                return element
            }
            current = copyAttribute(element, kAXParentAttribute as CFString)
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let attributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            "AXContents" as CFString,
            "AXRows" as CFString,
        ]
        for attribute in attributes {
            if let children: [AXUIElement] = copyAttribute(element, attribute), !children.isEmpty {
                return children
            }
        }
        return []
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute as CFString) else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    #if DEBUG
    /// Debug builds drop a redacted fixture of every click at a fixed path so a
    /// failing selection can be captured without hunting for a menu item. Text
    /// is already reduced to lengths and fingerprints — no conversation content.
    private func autoSaveFixture(_ snapshot: TargetSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: downloads.appendingPathComponent("magi-last-click.json"))
    }
    #endif

    func isElementAlive(_ element: AXUIElement) -> Bool {
        let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
        return role != nil
    }

    func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    func setValue(_ text: String, of element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }
}
