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
    private var keyboardEventMonitor: Any?
    private var universalEditorHotKey: EventHotKeyRef?
    private var universalEditorHotKeyHandler: EventHandlerRef?
    private var binding: ResponseBinding?
    private var editorBinding: EditorBinding?
    private var sourceApplicationPID: pid_t?
    private var lastExternalApplicationPID: pid_t?
    private var lastTerminalEditorRequest = Date.distantPast
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
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplicationPID = application.processIdentifier
        }
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

        let universalEditorItem = NSMenuItem(title: "Open Terminal Editor (Option-M or Control-Option-click)", action: #selector(openUniversalTerminalEditor), keyEquivalent: "")
        universalEditorItem.target = self
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
        logger.notice("Keyboard listening access: \(CGPreflightListenEventAccess())")
        keyboardEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard UniversalEditorShortcut.matches(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) else { return }
            MainActor.assumeIsolated {
                self?.openUniversalTerminalEditor()
            }
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                ) == noErr,
                hotKeyID.signature == OSType(0x4D41_4749), hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
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
        let shortcutStatus = RegisterEventHotKey(
            UniversalEditorShortcut.keyCode,
            UniversalEditorShortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &universalEditorHotKey
        )
        logger.notice("Terminal editor shortcut registration: handler=\(handlerStatus) shortcut=\(shortcutStatus)")
    }

    @objc private func openUniversalTerminalEditor() {
        let now = Date()
        guard now.timeIntervalSince(lastTerminalEditorRequest) > 0.2 else { return }
        lastTerminalEditorRequest = now

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let applicationPID = frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplicationPID
            : frontmostApplication?.processIdentifier
        let bundleIdentifier = applicationPID
            .flatMap(NSRunningApplication.init(processIdentifier:))?.bundleIdentifier ?? "unknown"
        let trusted = AXIsProcessTrusted()
        logger.notice("Terminal editor requested: app=\(bundleIdentifier, privacy: .public) enabled=\(self.enabled) accessibility=\(trusted)")
        guard enabled else { return }
        guard trusted else {
            promptForAccessibilityIfNeeded()
            return
        }

        do {
            let source = try accessibility.frontmostTerminalEditorSource(applicationPID: applicationPID)
            startEditing(source)
            logger.notice("Terminal editor opened: app=\(source.bundleIdentifier, privacy: .public)")
        } catch {
            logger.error("Universal terminal editor failed: \(error.localizedDescription, privacy: .public)")
            readerPanel.showMessage("Magi could not open the focused terminal. Click inside the terminal, then press Option-M again.")
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard enabled else { return }
        if UniversalEditorShortcut.matchesMouse(modifierFlags: event.modifierFlags),
           let application = NSWorkspace.shared.frontmostApplication,
           let bundleIdentifier = application.bundleIdentifier,
           SupportedApplication.isTerminal(
               bundleIdentifier: bundleIdentifier,
               applicationName: application.localizedName ?? bundleIdentifier
           ) {
            openUniversalTerminalEditor()
            return
        }
        guard trigger.matches(event.modifierFlags) else { return }
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
            case .capturedResponse(let snapshot):
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

    private func startReading(_ snapshot: CapturedResponseSnapshot) {
        clearBindings()
        sourceApplicationPID = snapshot.applicationPID
        sourceHighlight.flash(responseFrame: snapshot.responseFrame, inside: snapshot.windowFrame)
        readerPanel.show(
            snapshot.text,
            promptContext: nil,
            attachedTo: snapshot.windowFrame,
            connectionState: .captured
        )
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
        case .requiresPaste:
            let source = editorBinding.source
            NSRunningApplication(processIdentifier: source.applicationPID)?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                guard self.accessibility.isValidTerminalSource(source),
                      let transaction = PasteboardTransaction(text: editorBinding.draft) else {
                    self.readerPanel.showEditorStatus("The original terminal is no longer available. Your draft is preserved here.", isError: true)
                    return
                }
                self.accessibility.focus(source.element)
                if self.accessibility.replaceTerminalInput(for: source) {
                    self.readerPanel.showEditorStatus("Applied to \(source.applicationName). Nothing was submitted.", isError: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        transaction.restoreIfOwned()
                    }
                } else {
                    transaction.restoreIfOwned()
                    self.readerPanel.showEditorStatus("Could not paste into \(source.applicationName). Your draft is preserved here.", isError: true)
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
            readerPanel.showMessage("Saved anonymized Accessibility fixture to \(url.path). Content strings were removed; only structural data and known control categories remain.")
        } catch {
            readerPanel.showMessage("Could not save fixture: \(error.localizedDescription)")
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard runningApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplicationPID = runningApplication.processIdentifier
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

    static func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant = modifierFlags.intersection([.command, .control, .option, .shift])
        return UInt32(keyCode) == Self.keyCode && relevant == [.option]
    }

    static func matchesMouse(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifierFlags.intersection([.command, .control, .option, .shift])
        return relevant == [.control, .option]
    }
}
