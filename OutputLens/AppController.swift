import AppKit
import ApplicationServices

@MainActor
final class AppController: NSObject {
    private let supportedBundleIdentifiers = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
    ]

    private let accessibility = AccessibilityClient()
    private let readerPanel = ReaderPanelController()
    private let sourceHighlight = SourceHighlightController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var eventMonitor: Any?
    private var binding: ResponseBinding?
    private var sourceApplicationPID: pid_t?
    private var enabled = true
    private var trigger = Trigger.load()

    func start() {
        readerPanel.onUserClose = { [weak self] in
            self?.clearReadingSession()
        }
        configureStatusItem()
        requestAccessibilityPermission()
        installEventMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Output Lens")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: enabled ? "Disable Output Lens" : "Enable Output Lens", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Activation Click", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        for option in Trigger.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == trigger ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let permissionItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let closeItem = NSMenuItem(title: "Close Reading Panel", action: #selector(closePanel), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Output Lens", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDown(event)
            }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard enabled, trigger.matches(event.modifierFlags) else { return }
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }

        let point = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)

        do {
            let snapshot = try accessibility.response(at: point, supportedBundleIdentifiers: supportedBundleIdentifiers)
            binding?.invalidate()
            binding = ResponseBinding(snapshot: snapshot, accessibility: accessibility) { [weak self] update in
                self?.readerPanel.show(update.text, attachedTo: update.windowFrame, connectionState: update.connectionState)
            }
            sourceApplicationPID = snapshot.applicationPID
            sourceHighlight.flash(responseFrame: snapshot.responseFrame, inside: snapshot.windowFrame)
            readerPanel.show(snapshot.text, attachedTo: snapshot.windowFrame, connectionState: .connected)
        } catch {
            readerPanel.showMessage(error.localizedDescription)
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if !enabled {
            clearReadingSession()
            readerPanel.close()
        }
        rebuildMenu()
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = Trigger(rawValue: rawValue) else { return }
        trigger = selected
        trigger.save()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closePanel() {
        clearReadingSession()
        readerPanel.close()
    }

    private func clearReadingSession() {
        binding?.invalidate()
        binding = nil
        sourceApplicationPID = nil
        sourceHighlight.hide()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let sourceApplicationPID else { return }
        readerPanel.setVisible(runningApplication.processIdentifier == sourceApplicationPID)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private enum Trigger: String, CaseIterable {
    case option
    case controlOption
    case commandOption
    case shiftOption

    var title: String {
        switch self {
        case .option: "Option-click"
        case .controlOption: "Control-Option-click"
        case .commandOption: "Command-Option-click"
        case .shiftOption: "Shift-Option-click"
        }
    }

    private var requiredFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: [.option]
        case .controlOption: [.control, .option]
        case .commandOption: [.command, .option]
        case .shiftOption: [.shift, .option]
        }
    }

    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .control, .option, .shift])
        return relevant == requiredFlags
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "activationTrigger")
    }

    static func load() -> Trigger {
        guard let value = UserDefaults.standard.string(forKey: "activationTrigger") else { return .option }
        return Trigger(rawValue: value) ?? .option
    }
}
