import AppKit
import ApplicationServices

@MainActor
final class AppController: NSObject {
    private let supportedBundleIdentifiers = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    private let accessibility = AccessibilityClient()
    private let clipboardReader = ClipboardReader()
    private let readerPanel = ReaderPanelController()
    private let sourceHighlight = SourceHighlightController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var eventMonitor: Any?
    private var binding: ResponseBinding?
    private var editorBinding: EditorBinding?
    private var sourceApplicationPID: pid_t?
    private var clipboardText = ""
    private var forceNextClipboard = false
    private var hasPromptedForAccessibility = false
    private var clipboardWatching = UserDefaults.standard.bool(forKey: "clipboardWatching")
    private var enabled = true
    private var trigger = Trigger.load()

    func start() {
        readerPanel.onUserClose = { [weak self] in
            self?.clearReadingSession()
        }
        readerPanel.onApplyEditor = { [weak self] draft in
            self?.applyEditorDraft(draft)
        }
        readerPanel.onCancelEditor = { [weak self] in
            self?.clearReadingSession()
            self?.readerPanel.close()
        }
        readerPanel.onEditorDraftChange = { [weak self] draft in
            self?.editorBinding?.updateDraft(draft)
        }
        clipboardReader.onNewText = { [weak self] text in
            self?.handleClipboardText(text)
        }
        if clipboardWatching {
            clipboardReader.startWatching()
        }
        configureStatusItem()
        installEventMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Magi")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: enabled ? "Disable Magi" : "Enable Magi", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        menu.addItem(.separator())
        let clipboardHeading = NSMenuItem(title: "Copy to Magi (no permission)", action: nil, keyEquivalent: "")
        clipboardHeading.isEnabled = false
        menu.addItem(clipboardHeading)

        let watchItem = NSMenuItem(title: "Watch Clipboard", action: #selector(toggleClipboardWatching), keyEquivalent: "")
        watchItem.target = self
        watchItem.state = clipboardWatching ? .on : .off
        menu.addItem(watchItem)

        let pasteItem = NSMenuItem(title: "Show Clipboard Now", action: #selector(showClipboardNow), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Option-Click (needs Accessibility)", action: nil, keyEquivalent: "")
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

        let fixtureItem = NSMenuItem(title: "Save Anonymized Click Fixture…", action: #selector(saveDiagnosticFixture), keyEquivalent: "")
        fixtureItem.target = self
        menu.addItem(fixtureItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Magi", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Ask macOS to show the Accessibility prompt, but only when the user
    /// actually invokes Option-click without the permission — never at launch,
    /// and only once per session so we do not re-open the dialog on every
    /// click. Clipboard capture never reaches here because it needs no access.
    private func promptForAccessibilityIfNeeded() {
        if hasPromptedForAccessibility {
            readerPanel.showMessage("Option-click needs Accessibility access. Choose “Open Accessibility Settings…” from the Magi menu, enable Magi, then try again. Copy to Magi works without it.")
            return
        }
        hasPromptedForAccessibility = true
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
            promptForAccessibilityIfNeeded()
            return
        }

        let point = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)

        do {
            switch try accessibility.target(at: point, supportedBundleIdentifiers: supportedBundleIdentifiers) {
            case .response(let snapshot):
                startReading(snapshot)
            case .editor(let source):
                startEditing(source)
            }
        } catch AccessibilityClientError.responseBoundaryNotIdentified {
            readerPanel.showSelectionFailure(AccessibilityClientError.responseBoundaryNotIdentified.localizedDescription)
        } catch {
            readerPanel.showMessage(error.localizedDescription)
        }
    }

    private func startReading(_ snapshot: ResponseSnapshot) {
        clearBindings()
        binding = ResponseBinding(snapshot: snapshot, accessibility: accessibility) { [weak self] update in
            self?.readerPanel.show(update.text, promptContext: update.promptContext, attachedTo: update.windowFrame, connectionState: update.connectionState)
        }
        sourceApplicationPID = snapshot.applicationPID
        sourceHighlight.flash(responseFrame: snapshot.responseFrame, inside: snapshot.windowFrame)
        readerPanel.show(snapshot.text, promptContext: snapshot.promptContext, attachedTo: snapshot.windowFrame, connectionState: .connected)
    }

    private func startEditing(_ source: EditorSource) {
        clearBindings()
        editorBinding = EditorBinding(source: source)
        sourceApplicationPID = source.applicationPID
        readerPanel.showEditor(
            draft: source.originalText,
            statusText: "\(source.applicationName) — \(source.capability.statusDescription)",
            attachedTo: source.windowFrame
        )
    }

    private func applyEditorDraft(_ draft: String) {
        guard let editorBinding else { return }
        editorBinding.updateDraft(draft)
        switch editorBinding.apply(using: accessibility) {
        case .applied:
            readerPanel.showEditorStatus("Applied to \(editorBinding.source.applicationName). Nothing was submitted.", isError: false)
        case .copiedForPaste:
            clipboardReader.ignoreCurrentChange()
            accessibility.focus(editorBinding.source.element)
            NSRunningApplication(processIdentifier: editorBinding.source.applicationPID)?.activate()
            readerPanel.showEditorStatus("Copied. Paste in \(editorBinding.source.applicationName) when ready; nothing was executed.", isError: false)
        case .failed(let reason):
            readerPanel.showEditorStatus(reason, isError: true)
        }
    }

    private func handleClipboardText(_ text: String) {
        guard enabled else { return }
        // Ignore a selection the user copied out of the reader itself, which
        // would otherwise replace the response with a fragment of itself.
        // An explicit "Show Clipboard Now" bypasses this guard.
        if !forceNextClipboard, !clipboardText.isEmpty, clipboardText.contains(text) { return }
        clipboardText = text
        clearBindings()
        sourceApplicationPID = nil
        sourceHighlight.hide()
        readerPanel.showClipboardText(text)
    }

    @objc private func toggleClipboardWatching() {
        clipboardWatching.toggle()
        UserDefaults.standard.set(clipboardWatching, forKey: "clipboardWatching")
        if clipboardWatching, enabled {
            clipboardReader.startWatching()
        } else {
            clipboardReader.stopWatching()
        }
        rebuildMenu()
    }

    @objc private func showClipboardNow() {
        forceNextClipboard = true
        clipboardReader.captureNow()
        forceNextClipboard = false
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            if clipboardWatching { clipboardReader.startWatching() }
        } else {
            clipboardReader.stopWatching()
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

    private func clearBindings() {
        binding?.invalidate()
        binding = nil
        editorBinding = nil
    }

    private func clearReadingSession() {
        clearBindings()
        sourceApplicationPID = nil
        sourceHighlight.hide()
    }

    @objc private func saveDiagnosticFixture() {
        guard let snapshot = accessibility.lastRedactedSnapshot else {
            readerPanel.showMessage("No click captured yet. Option-click in Codex or Claude first, then save the fixture.")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = ISO8601DateFormatter()
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("magi-fixture-\(formatter.string(from: .now)).json")
        do {
            try encoder.encode(snapshot).write(to: url)
            readerPanel.showMessage("Saved anonymized Accessibility fixture to \(url.path). Text is redacted to lengths and fingerprints.")
        } catch {
            readerPanel.showMessage("Could not save fixture: \(error.localizedDescription)")
        }
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
