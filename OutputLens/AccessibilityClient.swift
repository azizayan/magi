import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

struct CapturedResponseSnapshot {
    let applicationPID: pid_t
    let text: String
    let responseFrame: CGRect
    let windowFrame: CGRect
}

enum ResolvedTarget {
    case response(ResponseSnapshot)
    case capturedResponse(CapturedResponseSnapshot)
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
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.electron.ollama",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.vscodium",
        "com.codeium.windsurf",
        "com.google.antigravity",
    ]
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let cliResponseStore = CLIResponseStore()
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
            return .capturedResponse(try terminalResponseSnapshot(
                hitElement: resolvedHitElement,
                applicationPID: pid,
                clickPoint: point
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
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            ))
        }

        // Claude's Electron surface can return a full-size overlay/group from
        // coordinate hit-testing even after the underlying composer receives
        // focus. Accept the focused editable element only when its own frame
        // contains this click, so a previously focused composer cannot turn a
        // response click into Editor mode.
        if SupportedApplication.desktopBundleIdentifiers.contains(bundleIdentifier),
           let editableElement = focusedEditableElement(
               applicationPID: pid,
               containing: point
           ) {
            logger.notice("Resolved focused editable fallback bundle=\(bundleIdentifier, privacy: .public)")
            return .editor(try editorSource(
                element: editableElement,
                applicationPID: pid,
                bundleIdentifier: bundleIdentifier,
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
        logger.notice("Snapshot:\n\(SnapshotRedaction.structuralSummary(snapshot), privacy: .public)")
        #endif

        switch targetKind {
        case .terminalInput(let nodeID):
            guard let element = elementsByNodeID[nodeID] else {
                throw AccessibilityClientError.noElement
            }
            return .capturedResponse(try terminalResponseSnapshot(
                hitElement: element,
                applicationPID: pid,
                clickPoint: point
            ))
        case .editableInput(let nodeID):
            guard SupportedApplication.allowsDirectEditor(bundleIdentifier: bundleIdentifier) else {
                throw AccessibilityClientError.noReadableResponse
            }
            return .editor(try editorSource(
                nodeID: nodeID,
                applicationPID: pid,
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            ))
        case .assistantResponse:
            guard SupportedApplication.allowsResponseReader(bundleIdentifier: bundleIdentifier) else {
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

    /// Open the safe paste-based editor for a recognized terminal host or a
    /// focused element whose Accessibility ancestry carries a terminal marker.
    func frontmostTerminalEditorSource(applicationPID: pid_t? = nil) throws -> EditorSource {
        let application = applicationPID.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? NSWorkspace.shared.frontmostApplication
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = application.bundleIdentifier else {
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
        let applicationName = application.localizedName ?? bundleIdentifier
        guard SupportedApplication.allowsUniversalTerminalEditor(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            focusedElementHasTerminalMarker: focusedElement.map(hasTerminalMarker(inAncestorsOf:)) ?? false
        ) else {
            throw AccessibilityClientError.unsupportedApplication
        }

        return try terminalEditorSource(
            hitElement: sourceElement,
            applicationPID: pid,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            prefersFocusedElement: true
        )
    }

    private func adapter(for bundleIdentifier: String) -> any ResponseAdapter {
        switch bundleIdentifier {
        case "com.anthropic.claudefordesktop": ClaudeResponseAdapter()
        case "com.todesktop.230313mzl4w4u92": CursorResponseAdapter()
        default: CodexResponseAdapter()
        }
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

        logger.notice("Selected adapter=\(resolution.adapterName, privacy: .public) section=\(resolution.sectionIndex) of clusters=\(resolution.clusterCount) chars=\(resolution.text.count)")

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
        bundleIdentifier: String,
        applicationName: String
    ) throws -> EditorSource {
        guard let element = elementsByNodeID[nodeID] else {
            throw AccessibilityClientError.noElement
        }
        return try editorSource(
            element: element,
            applicationPID: applicationPID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
    }

    private func editorSource(
        element: AXUIElement,
        applicationPID: pid_t,
        bundleIdentifier: String,
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
            bundleIdentifier: bundleIdentifier,
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
        bundleIdentifier: String,
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
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            element: sourceElement,
            windowElement: window,
            windowFrame: windowFrame,
            capability: .pasteRequired,
            originalText: ""
        )
    }

    /// Resolve one completed terminal output. Exact Codex/Claude hook records
    /// win when their text is visible in the clicked terminal; otherwise Magi
    /// uses the shell prompts surrounding the clicked line as hard boundaries.
    private func terminalResponseSnapshot(
        hitElement: AXUIElement,
        applicationPID: pid_t,
        clickPoint: CGPoint
    ) throws -> CapturedResponseSnapshot {
        let application = AXUIElementCreateApplication(applicationPID)
        let focusedElement: AXUIElement? = copyAttribute(
            application,
            kAXFocusedUIElementAttribute as CFString
        )
        let candidates = terminalTextCandidates(hitElement: hitElement, focusedElement: focusedElement)
        guard let candidate = candidates.max(by: { $0.text.utf16.count < $1.text.utf16.count }) else {
            throw AccessibilityClientError.noReadableResponse
        }

        let window: AXUIElement? = copyAttribute(candidate.element, kAXWindowAttribute as CFString)
            ?? copyAttribute(hitElement, kAXWindowAttribute as CFString)
            ?? copyAttribute(application, kAXFocusedWindowAttribute as CFString)
        guard let window, let windowFrame = frame(of: window) else {
            throw AccessibilityClientError.noWindow
        }

        let characterIndex = terminalCharacterIndex(
            at: clickPoint,
            in: candidate.element,
            terminalText: candidate.text,
            hitElement: hitElement
        )
        let exactResponse = cliResponseStore.response(
            matching: candidate.text,
            characterIndex: characterIndex
        )?.text
        guard let response = exactResponse ?? TerminalOutputExtractor.block(
            in: candidate.text,
            characterIndex: characterIndex
        ) else {
            throw AccessibilityClientError.responseBoundaryNotIdentified
        }

        return CapturedResponseSnapshot(
            applicationPID: applicationPID,
            text: response,
            responseFrame: frame(of: candidate.element) ?? windowFrame,
            windowFrame: windowFrame
        )
    }

    private func terminalTextCandidates(
        hitElement: AXUIElement,
        focusedElement: AXUIElement?
    ) -> [(element: AXUIElement, text: String)] {
        var elements: [AXUIElement] = []
        for start in [hitElement, focusedElement].compactMap({ $0 }) {
            var current: AXUIElement? = start
            for _ in 0..<12 {
                guard let element = current else { break }
                if !elements.contains(where: { CFEqual($0, element) }) {
                    elements.append(element)
                }
                current = copyAttribute(element, kAXParentAttribute as CFString)
            }
        }
        return elements.compactMap { element in
            guard let text: String = copyAttribute(element, kAXValueAttribute as CFString),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (element, ResponseHeuristics.normalizeLineEndings(text))
        }
    }

    private func characterIndex(at point: CGPoint, in element: AXUIElement) -> Int? {
        var point = point
        guard let pointValue = AXValueCreate(.cgPoint, &point) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForPositionParameterizedAttribute as CFString,
            pointValue,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range.location >= 0 ? range.location : nil
    }

    private func terminalCharacterIndex(
        at point: CGPoint,
        in terminalElement: AXUIElement,
        terminalText: String,
        hitElement: AXUIElement
    ) -> Int? {
        if let index = characterIndex(at: point, in: terminalElement) {
            return index
        }
        guard !CFEqual(terminalElement, hitElement),
              let hitText: String = copyAttribute(hitElement, kAXValueAttribute as CFString) else {
            return nil
        }
        let normalizedHitText = ResponseHeuristics.normalizeLineEndings(hitText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedHitText.count >= 2,
              let range = terminalText.range(of: normalizedHitText) else { return nil }
        return terminalText.utf16.distance(
            from: terminalText.utf16.startIndex,
            to: range.lowerBound.samePosition(in: terminalText.utf16) ?? terminalText.utf16.startIndex
        )
    }

    // MARK: - Streaming refresh

    /// Re-resolve the bound message from a fresh snapshot of the same
    /// container. Returns nil when the message identity cannot be confirmed.
    func refreshResponse(_ snapshot: ResponseSnapshot, previousText: String) -> ResponseResolution? {
        let started = CFAbsoluteTimeGetCurrent()
        var builder = SnapshotBuilder(hitElement: snapshot.containerElement, budget: 3000)
        guard let root = build(snapshot.containerElement, depth: 0, builder: &builder) else { return nil }
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        if builder.nextID >= 2_000 || elapsedMilliseconds >= 50 {
            logger.notice("Accessibility refresh nodes=\(builder.nextID, privacy: .public) duration_ms=\(elapsedMilliseconds, privacy: .public)")
        }
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

    private func focusedEditableElement(
        applicationPID: pid_t,
        containing point: CGPoint
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(applicationPID)
        guard let element: AXUIElement = copyAttribute(
            application,
            kAXFocusedUIElementAttribute as CFString
        ) else { return nil }
        let role: String = copyAttribute(element, kAXRoleAttribute as CFString) ?? ""
        guard TargetClassifier.focusedEditableContainsClick(
            role: role,
            isValueSettable: isValueSettable(element),
            frame: frame(of: element),
            point: point
        ) else { return nil }
        return element
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

    private func hasTerminalMarker(inAncestorsOf element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            let node = SnapshotNode(
                id: 0,
                role: copyAttribute(candidate, kAXRoleAttribute as CFString) ?? "",
                identifier: copyAttribute(candidate, kAXIdentifierAttribute as CFString) ?? "",
                label: copyAttribute(candidate, kAXDescriptionAttribute as CFString) ?? "",
                isValueSettable: isValueSettable(candidate)
            )
            if TargetClassifier.isTerminalSurface(node) { return true }
            current = copyAttribute(candidate, kAXParentAttribute as CFString)
        }
        return false
    }

    func isValidTerminalSource(_ source: EditorSource) -> Bool {
        guard source.capability == .pasteRequired,
              isElementAlive(source.element),
              isElementAlive(source.windowElement),
              let runningApplication = NSRunningApplication(processIdentifier: source.applicationPID),
              runningApplication.bundleIdentifier == source.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == source.applicationPID else {
            return false
        }

        let application = AXUIElementCreateApplication(source.applicationPID)
        let focusedWindow: AXUIElement? = copyAttribute(application, kAXFocusedWindowAttribute as CFString)
        return focusedWindow.map { CFEqual($0, source.windowElement) } ?? false
    }

    static let terminalReplacementKeystrokes: [(keyCode: CGKeyCode, flags: CGEventFlags)] = [
        (CGKeyCode(kVK_ANSI_E), .maskControl),
        (CGKeyCode(kVK_ANSI_U), .maskControl),
        (CGKeyCode(kVK_ANSI_V), .maskCommand),
    ]

    /// Replace the source terminal's current prompt with the prepared draft.
    /// Control-E moves to the end, Control-U clears back to the beginning, and
    /// Command-V pastes the draft. Return is never emitted.
    func replaceTerminalInput(for sourceTarget: EditorSource) -> Bool {
        guard isValidTerminalSource(sourceTarget) else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        for stroke in Self.terminalReplacementKeystrokes {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: false
            ) else { return false }
            keyDown.flags = stroke.flags
            keyUp.flags = stroke.flags
            keyDown.postToPid(sourceTarget.applicationPID)
            keyUp.postToPid(sourceTarget.applicationPID)
        }
        return true
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }
}
