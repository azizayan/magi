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
    let bundleIdentifier: String
    let applicationName: String
    let element: AXUIElement
    let windowElement: AXUIElement
    let windowFrame: CGRect
    let capability: WriteBackCapability
    let originalText: String
}

enum EditorApplyResult: Equatable {
    case applied
    case requiresPaste
    case failed(String)
}

/// Owns Magi's short-lived pasteboard replacement. The previous pasteboard is
/// restored only while Magi's private marker is still present, so a clipboard
/// change made by the user or another app is never overwritten.
@MainActor
final class PasteboardTransaction {
    private static let markerType = NSPasteboard.PasteboardType("com.azizemreayan.magi.transient-paste")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let previousItems: [[NSPasteboard.PasteboardType: Data]]
    private let marker = UUID().uuidString

    init?(text: String, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        previousItems = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []

        let temporaryItem = NSPasteboardItem()
        temporaryItem.setString(text, forType: .string)
        temporaryItem.setString(marker, forType: Self.markerType)
        temporaryItem.setData(Data(), forType: Self.transientType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([temporaryItem]) else { return nil }
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        guard pasteboard.string(forType: Self.markerType) == marker else { return false }

        let restoredItems = previousItems.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.clearContents()
        if !restoredItems.isEmpty {
            _ = pasteboard.writeObjects(restoredItems)
        }
        return true
    }
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
            focus: accessibility.focus
        )
    }

    func apply(
        isElementAlive: (AXUIElement) -> Bool,
        setValue: (String, AXUIElement) -> Bool,
        focus: (AXUIElement) -> Void
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
            return .requiresPaste
        case .unavailable:
            return .failed("This input does not support write-back. Your draft is preserved here.")
        }
    }
}
