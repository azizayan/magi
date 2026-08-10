import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

@MainActor
final class AppController: NSObject {
    private let logger = Logger(subsystem: "com.azizemreayan.OutputLens", category: "AppController")
    private let accessibility = AccessibilityClient()
    private let readerPanel = ReaderPanelController()
    private let sourceHighlight = SourceHighlightController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var eventMonitor: Any?
    private var universalEditorHotKey: EventHotKeyRef?
    private var universalEditorHotKeyHandler: EventHandlerRef?
    private var binding: ResponseBinding?
    private var editorBinding: EditorBinding?
    private var sourceApplicationPID: pid_t?
    private var hasPromptedForAccessibility = false
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
        configureStatusItem()
        installEventMonitor()
        installKeyboardMonitor()
        prepareRunningSourceApplications()
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
        let heading = NSMenuItem(title: "Option-Click (needs Accessibility)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        let universalEditorItem = NSMenuItem(title: "Option-M: Open Editor for Frontmost Terminal", action: nil, keyEquivalent: "")
        universalEditorItem.isEnabled = false
        menu.addItem(universalEditorItem)

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
    /// click.
    private func promptForAccessibilityIfNeeded() {
        if hasPromptedForAccessibility {
            readerPanel.showMessage("Option-click needs Accessibility access. Choose “Open Accessibility Settings…” from the Magi menu, enable Magi, then try again.")
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

    private func installKeyboardMonitor() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.openUniversalTerminalEditor()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &universalEditorHotKeyHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D41_4749), id: 1) // MAGI
        RegisterEventHotKey(
            UniversalEditorShortcut.keyCode,
            UniversalEditorShortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &universalEditorHotKey
        )
    }

    private func openUniversalTerminalEditor() {
        guard enabled else { return }
        guard AXIsProcessTrusted() else {
            promptForAccessibilityIfNeeded()
            return
        }

        do {
            startEditing(try accessibility.frontmostTerminalEditorSource())
        } catch {
            logger.error("Universal terminal editor failed: \(error.localizedDescription, privacy: .public)")
            readerPanel.showMessage("Magi could not open the focused terminal. Click inside the terminal, then press Option-M again.")
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard enabled, trigger.matches(event.modifierFlags) else { return }
        guard AXIsProcessTrusted() else {
            promptForAccessibilityIfNeeded()
            return
        }

        let point = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        resolveTarget(at: point, retryIfUnavailable: true)
    }

    private func resolveTarget(at point: CGPoint, retryIfUnavailable: Bool = false) {
        do {
            switch try accessibility.target(at: point) {
            case .response(let snapshot):
                startReading(snapshot)
            case .editor(let source):
                startEditing(source)
            }
        } catch AccessibilityClientError.responseBoundaryNotIdentified {
            readerPanel.showSelectionFailure(AccessibilityClientError.responseBoundaryNotIdentified.localizedDescription)
        } catch AccessibilityClientError.noReadableResponse where retryIfUnavailable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.resolveTarget(at: point)
            }
        } catch {
            logger.error("Target resolution failed: \(error.localizedDescription, privacy: .public)")
            readerPanel.showMessage(error.localizedDescription)
        }
    }

    private func prepareRunningSourceApplications() {
        guard AXIsProcessTrusted() else { return }
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier,
                  SupportedApplication.isSupported(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: application.localizedName ?? bundleIdentifier
                  ) else { continue }
            accessibility.prepareApplicationAccessibility(
                applicationPID: application.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
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
            let source = editorBinding.source
            NSRunningApplication(processIdentifier: source.applicationPID)?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.accessibility.focus(source.element)
                if self.accessibility.replaceTerminalInput(inApplication: source.applicationPID) {
                    self.readerPanel.showEditorStatus("Applied to \(source.applicationName). Nothing was submitted.", isError: false)
                } else {
                    self.readerPanel.showEditorStatus("Copied. Press Command-V in \(source.applicationName); nothing was submitted.", isError: false)
                }
            }
        case .failed(let reason):
            readerPanel.showEditorStatus(reason, isError: true)
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
        guard let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard runningApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let bundleIdentifier = runningApplication.bundleIdentifier,
           SupportedApplication.isSupported(
            bundleIdentifier: bundleIdentifier,
            applicationName: runningApplication.localizedName ?? bundleIdentifier
           ),
           AXIsProcessTrusted() {
            accessibility.prepareApplicationAccessibility(
                applicationPID: runningApplication.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
        guard let sourceApplicationPID else { return }
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

enum UniversalEditorShortcut {
    static let keyCode = UInt32(kVK_ANSI_M)
    static let carbonModifiers = UInt32(optionKey)

    static func matches(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant = modifierFlags.intersection([.command, .control, .option, .shift])
        return charactersIgnoringModifiers?.lowercased() == "m" && relevant == [.option]
    }
}
