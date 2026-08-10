import AppKit
import ApplicationServices
import XCTest
@testable import OutputLens

@MainActor
final class AccessibilityIntegrationTests: XCTestCase {
    func testLiveDirectWriteAndTerminalPasteNeverSubmit() async throws {
        guard ProcessInfo.processInfo.environment["MAGI_RUN_AX_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MAGI_RUN_AX_INTEGRATION=1 to run the live Accessibility test.")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Grant Accessibility to the Xcode test host, then rerun.")
        }

        let productsURL = Bundle.main.bundleURL.deletingLastPathComponent()
        let hostURL = productsURL.appendingPathComponent("MagiIntegrationHost.app")
        let application = try await NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        defer { application.terminate() }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let window = try await waitForElement(identifier: nil, role: kAXWindowRole as String, in: applicationElement)
        let input = try await waitForElement(identifier: "magi-integration-input", role: nil, in: applicationElement)
        let submitCount = try await waitForElement(identifier: "magi-integration-submit-count", role: nil, in: applicationElement)
        let accessibility = AccessibilityClient()

        XCTAssertTrue(accessibility.setValue("direct write", of: input))
        XCTAssertEqual(value(of: input), "direct write")

        XCTAssertTrue(accessibility.setValue("old command", of: input))
        application.activate()
        accessibility.focus(input)
        try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier }
        let source = EditorSource(
            applicationPID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "com.azizemreayan.MagiIntegrationHost",
            applicationName: application.localizedName ?? "Integration Host",
            element: input,
            windowElement: window,
            windowFrame: accessibility.frame(of: window) ?? .zero,
            capability: .pasteRequired,
            originalText: ""
        )
        let paste = try XCTUnwrap(PasteboardTransaction(text: "replacement command"))
        XCTAssertTrue(accessibility.replaceTerminalInput(for: source))
        try await waitUntil { self.value(of: input) == "replacement command" }
        paste.restoreIfOwned()

        XCTAssertEqual(value(of: input), "replacement command")
        XCTAssertEqual(value(of: submitCount), "0")
    }

    private func waitForElement(
        identifier: String?,
        role: String?,
        in root: AXUIElement
    ) async throws -> AXUIElement {
        var found: AXUIElement?
        try await waitUntil {
            found = self.findElement(identifier: identifier, role: role, in: root, remainingDepth: 12)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for the live Accessibility host.")
    }

    private func findElement(
        identifier: String?,
        role: String?,
        in element: AXUIElement,
        remainingDepth: Int
    ) -> AXUIElement? {
        guard remainingDepth >= 0 else { return nil }
        let candidateIdentifier: String? = attribute(element, kAXIdentifierAttribute as CFString)
        let candidateRole: String? = attribute(element, kAXRoleAttribute as CFString)
        if (identifier == nil || candidateIdentifier == identifier),
           (role == nil || candidateRole == role) {
            return element
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
        for child in children {
            if let found = findElement(
                identifier: identifier,
                role: role,
                in: child,
                remainingDepth: remainingDepth - 1
            ) {
                return found
            }
        }
        return nil
    }

    private func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute as CFString)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
}
