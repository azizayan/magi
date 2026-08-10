import AppKit
import Carbon.HIToolbox

@main
enum IntegrationHostMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = IntegrationHostDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.mainMenu = ApplicationMenu.make()
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class IntegrationHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let input = TerminalTextView(frame: .zero)
    private let submitCount = NSTextField(labelWithString: "0")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 640, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Magi Accessibility Integration Host"

        input.setAccessibilityIdentifier("magi-integration-input")
        input.setAccessibilityLabel("Terminal integration input")
        input.string = "original terminal input"
        input.isRichText = false
        input.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        input.onReturn = { [weak self] in
            self?.submitCount.integerValue += 1
        }
        submitCount.setAccessibilityIdentifier("magi-integration-submit-count")

        let inputScrollView = NSScrollView()
        inputScrollView.documentView = input
        inputScrollView.hasVerticalScroller = true
        inputScrollView.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Terminal-style editable control"),
            inputScrollView,
            NSTextField(labelWithString: "Submit count (must stay zero)"),
            submitCount,
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        NSApp.activate()
    }

}

@MainActor
private final class TerminalTextView: NSTextView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.keyCode == kVK_ANSI_E {
            setSelectedRange(NSRange(location: string.utf16.count, length: 0))
            return
        }
        if event.modifierFlags.contains(.control), event.keyCode == kVK_ANSI_U {
            let selection = selectedRange()
            textStorage?.replaceCharacters(in: NSRange(location: 0, length: selection.location), with: "")
            setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        if event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

private enum ApplicationMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }
}
