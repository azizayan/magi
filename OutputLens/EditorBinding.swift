import AppKit
import ApplicationServices

enum WriteBackCapability: String {
    case direct
    case pasteRequired
    case unavailable

    var statusDescription: String {
        switch self {
        case .direct: "direct write-back available"
        case .pasteRequired: "write-back by paste only"
        case .unavailable: "write-back unavailable"
        }
    }
}

struct EditorSource {
    let applicationPID: pid_t
    let applicationName: String
    let element: AXUIElement
    let windowElement: AXUIElement
    let windowFrame: CGRect
    let capability: WriteBackCapability
    let originalText: String
}

enum EditorApplyResult: Equatable {
    case applied
    case copiedForPaste
    case failed(String)
}

/// The editor binding survives independently of the source element so a draft
/// is never lost: when the source disappears, applying fails with an error and
/// the draft stays in the panel.
@MainActor
final class EditorBinding {
    let source: EditorSource
    private(set) var draft: String

    init(source: EditorSource) {
        self.source = source
        self.draft = source.originalText
    }

    func updateDraft(_ text: String) {
        draft = text
    }

    /// Write the draft back to the source input. This only sets the element's
    /// value; it never presses Enter, submits a prompt, or runs a command.
    func apply(using accessibility: AccessibilityClient) -> EditorApplyResult {
        apply(
            isElementAlive: accessibility.isElementAlive,
            setValue: accessibility.setValue,
            focus: accessibility.focus,
            copyForPaste: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
        )
    }

    func apply(
        isElementAlive: (AXUIElement) -> Bool,
        setValue: (String, AXUIElement) -> Bool,
        focus: (AXUIElement) -> Void,
        copyForPaste: (String) -> Bool
    ) -> EditorApplyResult {
        switch source.capability {
        case .direct:
            guard isElementAlive(source.element) else {
                return .failed("The original input is no longer available. Your draft is preserved here.")
            }
            guard setValue(draft, source.element) else {
                return .failed("The input rejected the new text. Your draft is preserved here.")
            }
            focus(source.element)
            return .applied
        case .pasteRequired:
            guard copyForPaste(draft) else {
                return .failed("Magi could not copy the draft. Your draft is preserved here.")
            }
            return .copiedForPaste
        case .unavailable:
            return .failed("This input does not support write-back. Your draft is preserved here.")
        }
    }
}
