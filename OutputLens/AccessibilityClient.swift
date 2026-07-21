import AppKit
import ApplicationServices
import OSLog

struct ResponseSnapshot {
    let applicationPID: pid_t
    let responseElement: AXUIElement
    let windowElement: AXUIElement
    let text: String
    let responseFrame: CGRect
    let windowFrame: CGRect
}

enum AccessibilityClientError: LocalizedError {
    case noElement
    case unsupportedApplication
    case noReadableResponse
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noElement:
            "Output Lens could not find text at that point."
        case .unsupportedApplication:
            "Option-click a response inside the Codex or Claude desktop app."
        case .noReadableResponse:
            "That item does not expose a readable response. Try clicking directly on its text."
        case .noWindow:
            "Output Lens could not identify the source window."
        }
    }
}

final class AccessibilityClient {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let logger = Logger(subsystem: "com.azizemreayan.OutputLens", category: "ResponseSelection")

    func response(at point: CGPoint, supportedBundleIdentifiers: [String]) throws -> ResponseSnapshot {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success,
              let hitElement else {
            throw AccessibilityClientError.noElement
        }

        var pid: pid_t = 0
        AXUIElementGetPid(hitElement, &pid)
        guard let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              supportedBundleIdentifiers.contains(bundleIdentifier) else {
            throw AccessibilityClientError.unsupportedApplication
        }

        let candidates = ancestorCandidates(from: hitElement)
        guard let selected = ResponseHeuristics.selectCandidate(candidates), !selected.text.isEmpty else {
            throw AccessibilityClientError.noReadableResponse
        }

        guard let window: AXUIElement = copyAttribute(selected.element, kAXWindowAttribute as CFString),
              let frame = frame(of: window) else {
            throw AccessibilityClientError.noWindow
        }
        let responseFrame = self.frame(of: selected.element) ?? frame

        logCandidates(candidates, selected: selected)

        return ResponseSnapshot(
            applicationPID: pid,
            responseElement: selected.element,
            windowElement: window,
            text: selected.text,
            responseFrame: responseFrame,
            windowFrame: frame
        )
    }

    func text(of element: AXUIElement) -> String? {
        ResponseHeuristics.assemble(collectTextFragments(from: element, depth: 0, remainingNodes: 800))
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

    private func ancestorCandidates(from element: AXUIElement) -> [ResponseCandidate] {
        var candidates: [ResponseCandidate] = []
        var current: AXUIElement? = element

        for depth in 0..<12 {
            guard let node = current else { break }
            let role: String = copyAttribute(node, kAXRoleAttribute as CFString) ?? "unknown"
            let description: String = copyAttribute(node, kAXDescriptionAttribute as CFString) ?? ""
            let text = ResponseHeuristics.assemble(collectTextFragments(from: node, depth: 0, remainingNodes: 800))
            if !text.isEmpty {
                candidates.append(ResponseCandidate(
                    element: node,
                    depth: depth,
                    role: role,
                    description: description,
                    text: text,
                    actionNames: collectActionNames(from: node, depth: 0, remainingNodes: 300)
                ))
            }
            current = copyAttribute(node, kAXParentAttribute as CFString)
        }
        return candidates
    }

    private func collectTextFragments(from element: AXUIElement, depth: Int, remainingNodes: Int) -> [ResponseTextFragment] {
        guard depth <= 10, remainingNodes > 0 else { return [] }

        let role: String = copyAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == (kAXButtonRole as String),
           ResponseHeuristics.hasResponseControls(actionNames(of: element)) {
            return []
        }
        if let value: String = copyAttribute(element, kAXValueAttribute as CFString),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           role != (kAXButtonRole as String) {
            return [ResponseTextFragment(text: value, frame: frame(of: element), role: role)]
        }

        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as CFString),
              !children.isEmpty else { return [] }

        var fragments: [ResponseTextFragment] = []
        var budget = remainingNodes - 1
        for child in children where budget > 0 {
            let childFragments = collectTextFragments(from: child, depth: depth + 1, remainingNodes: budget)
            for fragment in childFragments {
                fragments.append(fragment)
            }
            budget -= 1
        }
        return fragments
    }

    private func collectActionNames(from element: AXUIElement, depth: Int, remainingNodes: Int) -> [String] {
        guard depth <= 8, remainingNodes > 0 else { return [] }

        let role: String = copyAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == (kAXButtonRole as String) {
            return actionNames(of: element)
        }

        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute as CFString) else { return [] }
        var names: [String] = []
        var budget = remainingNodes - 1
        for child in children where budget > 0 {
            names.append(contentsOf: collectActionNames(from: child, depth: depth + 1, remainingNodes: budget))
            budget -= 1
        }
        return names
    }

    private func actionNames(of button: AXUIElement) -> [String] {
        let values: [String?] = [
            copyAttribute(button, kAXTitleAttribute as CFString),
            copyAttribute(button, kAXDescriptionAttribute as CFString),
            copyAttribute(button, kAXHelpAttribute as CFString),
            copyAttribute(button, kAXIdentifierAttribute as CFString),
        ]
        return values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }

    private func logCandidates(_ candidates: [ResponseCandidate], selected: ResponseCandidate) {
        let summary = candidates.map { candidate in
            "depth=\(candidate.depth) role=\(candidate.role) chars=\(candidate.text.count) actions=\(candidate.actionNames.joined(separator: ","))\(candidate.depth == selected.depth ? " SELECTED" : "")"
        }.joined(separator: " | ")
        logger.notice("Candidates: \(summary, privacy: .public)")
    }
}
