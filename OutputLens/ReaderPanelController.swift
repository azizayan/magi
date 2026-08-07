import AppKit

enum PanelMode {
    case reader
    case editor
}

@MainActor
final class ReaderPanelController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onUserClose: (() -> Void)?
    var onApplyEditor: ((String) -> Void)?
    var onCancelEditor: (() -> Void)?
    var onEditorDraftChange: ((String) -> Void)?

    private(set) var mode: PanelMode = .reader

    private let textView = NSTextView()
    private let modeLabel = NSTextField(labelWithString: "Reader")
    private let stateLabel = NSTextField(labelWithString: "Connected")
    private let stateIndicator = NSTextField(labelWithString: "●")
    private let promptToggleButton = NSButton()
    private let smallerTextButton = NSButton()
    private let largerTextButton = NSButton()
    private let closePanelButton = NSButton()
    private let editorStatusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply to Input", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let actionBar = NSView()
    private var actionBarHeightConstraint: NSLayoutConstraint?
    private var lastText = ""
    private var lastPromptContext: String?
    private var showsPromptContext = UserDefaults.standard.bool(forKey: "showsPromptContext")
    private var proseFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "proseFontSize")
        return stored == 0 ? 24 : stored
    }()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Magi"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)
        panel.contentView = makeContentView()
        panel.delegate = self
        textView.delegate = self
        configureButtons()
        setMode(.reader)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Reader mode

    func show(_ text: String, promptContext: String?, attachedTo accessibilityFrame: CGRect, connectionState: ConnectionState) {
        setMode(.reader)
        let wasNearBottom = isNearBottom
        let promptChanged = promptContext != lastPromptContext
        lastPromptContext = promptContext
        updatePromptToggleVisibility()
        if text != lastText || promptChanged {
            textView.textStorage?.setAttributedString(renderReaderContent(response: text))
            lastText = text
            if wasNearBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        stateLabel.stringValue = connectionState == .connected ? "Connected" : "Connection paused"
        stateLabel.textColor = connectionState == .connected ? .secondaryLabelColor : .systemOrange
        stateIndicator.textColor = connectionState == .connected ? .systemGreen : .systemOrange

        if let frame = Self.panelFrame(attachedTo: accessibilityFrame) {
            window?.setFrame(frame, display: true, animate: window?.isVisible == true)
        }
        window?.orderFrontRegardless()
    }

    func showMessage(_ message: String) {
        setMode(.reader)
        lastText = message
        lastPromptContext = nil
        updatePromptToggleVisibility()
        textView.textStorage?.setAttributedString(Self.render(message, proseFontSize: proseFontSize))
        stateLabel.stringValue = "Not connected"
        stateLabel.textColor = .systemOrange
        stateIndicator.textColor = .systemOrange
        window?.center()
        window?.orderFrontRegardless()
    }

    /// Report a selection failure without discarding the currently displayed
    /// content: an ambiguous boundary must never replace a good response.
    func showSelectionFailure(_ message: String) {
        guard mode == .reader, window?.isVisible == true, !lastText.isEmpty else {
            showMessage(message)
            return
        }
        stateLabel.stringValue = message
        stateLabel.textColor = .systemOrange
        stateIndicator.textColor = .systemOrange
        window?.orderFrontRegardless()
    }

    // MARK: - Editor mode

    func showEditor(draft: String, statusText: String, attachedTo accessibilityFrame: CGRect) {
        setMode(.editor)
        lastText = draft
        textView.textStorage?.setAttributedString(Self.renderEditorText(draft, proseFontSize: proseFontSize))
        textView.typingAttributes = Self.editorAttributes(proseFontSize: proseFontSize)
        editorStatusLabel.stringValue = statusText
        editorStatusLabel.textColor = .secondaryLabelColor
        stateLabel.stringValue = "Editing draft"
        stateLabel.textColor = .secondaryLabelColor
        stateIndicator.textColor = .systemBlue

        if let frame = Self.panelFrame(attachedTo: accessibilityFrame) {
            window?.setFrame(frame, display: true, animate: window?.isVisible == true)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func showEditorStatus(_ message: String, isError: Bool) {
        editorStatusLabel.stringValue = message
        editorStatusLabel.textColor = isError ? .systemOrange : .secondaryLabelColor
    }

    var editorDraft: String { textView.string }

    func textDidChange(_ notification: Notification) {
        guard mode == .editor else { return }
        onEditorDraftChange?(textView.string)
    }

    /// The reader panel is a non-activating floating panel, so open links
    /// explicitly rather than relying on the default responder chain.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme != nil else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Shared

    override func close() {
        window?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onUserClose?()
    }

    private func setMode(_ newMode: PanelMode) {
        mode = newMode
        modeLabel.stringValue = newMode == .reader ? "Reader" : "Editor"
        textView.isEditable = newMode == .editor
        textView.allowsUndo = newMode == .editor
        actionBar.isHidden = newMode == .reader
        actionBarHeightConstraint?.constant = newMode == .reader ? 0 : 56
        updatePromptToggleVisibility()
    }

    private func updatePromptToggleVisibility() {
        let available = mode == .reader && !(lastPromptContext ?? "").isEmpty
        promptToggleButton.isHidden = !available
        let symbol = showsPromptContext ? "text.bubble.fill" : "text.bubble"
        promptToggleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle prompt")
        promptToggleButton.toolTip = showsPromptContext ? "Hide the prompt" : "Show the prompt that produced this response"
    }

    private func renderReaderContent(response: String) -> NSAttributedString {
        Self.composeReaderContent(
            promptContext: lastPromptContext,
            response: response,
            showsPrompt: showsPromptContext,
            proseFontSize: proseFontSize
        )
    }

    private var isNearBottom: Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return textView.bounds.maxY - visibleMaxY < 80
    }

    private func configureButtons() {
        promptToggleButton.target = self
        promptToggleButton.action = #selector(togglePromptContext)

        smallerTextButton.target = self
        smallerTextButton.action = #selector(makeTextSmaller)
        smallerTextButton.toolTip = "Smaller text"

        largerTextButton.target = self
        largerTextButton.action = #selector(makeTextLarger)
        largerTextButton.toolTip = "Larger text"

        closePanelButton.target = self
        closePanelButton.action = #selector(closeFromPanel)
        closePanelButton.toolTip = "Close Magi"

        applyButton.target = self
        applyButton.action = #selector(applyEditor)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = [.command]

        cancelButton.target = self
        cancelButton.action = #selector(cancelEditor)
        cancelButton.bezelStyle = .rounded
    }

    @objc private func makeTextSmaller() {
        setProseFontSize(max(18, proseFontSize - 2))
    }

    @objc private func makeTextLarger() {
        setProseFontSize(min(40, proseFontSize + 2))
    }

    @objc private func closeFromPanel() {
        window?.performClose(nil)
    }

    @objc private func togglePromptContext() {
        showsPromptContext.toggle()
        UserDefaults.standard.set(showsPromptContext, forKey: "showsPromptContext")
        updatePromptToggleVisibility()
        guard mode == .reader else { return }
        let wasNearBottom = isNearBottom
        textView.textStorage?.setAttributedString(renderReaderContent(response: lastText))
        if wasNearBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func applyEditor() {
        onApplyEditor?(textView.string)
    }

    @objc private func cancelEditor() {
        onCancelEditor?()
    }

    private func setProseFontSize(_ size: CGFloat) {
        guard size != proseFontSize else { return }
        proseFontSize = size
        UserDefaults.standard.set(size, forKey: "proseFontSize")
        if mode == .editor {
            let draft = textView.string
            textView.textStorage?.setAttributedString(Self.renderEditorText(draft, proseFontSize: proseFontSize))
            textView.typingAttributes = Self.editorAttributes(proseFontSize: proseFontSize)
        } else {
            textView.textStorage?.setAttributedString(renderReaderContent(response: lastText))
        }
    }

    private func makeContentView() -> NSView {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        modeLabel.font = .systemFont(ofSize: 13, weight: .bold)
        modeLabel.textColor = .labelColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        stateIndicator.font = .systemFont(ofSize: 10, weight: .bold)
        stateIndicator.textColor = .systemGreen
        stateIndicator.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.lineBreakMode = .byTruncatingTail

        Self.configureHeaderButton(promptToggleButton, symbol: "text.bubble", accessibilityLabel: "Show prompt")
        Self.configureHeaderButton(smallerTextButton, symbol: "textformat.size.smaller", accessibilityLabel: "Smaller text")
        Self.configureHeaderButton(largerTextButton, symbol: "textformat.size.larger", accessibilityLabel: "Larger text")
        Self.configureHeaderButton(closePanelButton, symbol: "xmark", accessibilityLabel: "Close Magi")
        promptToggleButton.isHidden = true

        let controls = NSStackView(views: [promptToggleButton, smallerTextButton, largerTextButton, closePanelButton])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false

        let status = NSStackView(views: [modeLabel, stateIndicator, stateLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 7
        status.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        scrollView.documentView = textView

        editorStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        editorStatusLabel.textColor = .secondaryLabelColor
        editorStatusLabel.lineBreakMode = .byTruncatingTail
        editorStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        applyButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(editorStatusLabel)
        actionBar.addSubview(applyButton)
        actionBar.addSubview(cancelButton)

        effectView.addSubview(status)
        effectView.addSubview(controls)
        effectView.addSubview(scrollView)
        effectView.addSubview(actionBar)

        let actionBarHeight = actionBar.heightAnchor.constraint(equalToConstant: 0)
        actionBarHeightConstraint = actionBarHeight

        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 28),
            status.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            actionBarHeight,
            actionBar.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            editorStatusLabel.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 28),
            editorStatusLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            editorStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
            applyButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -20),
            applyButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
        ])

        return effectView
    }

    private static func configureHeaderButton(_ button: NSButton, symbol: String, accessibilityLabel: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.controlSize = .regular
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    // MARK: - Editor rendering

    static func editorAttributes(proseFontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(4, proseFontSize * 0.18)
        return [
            .font: NSFont.monospacedSystemFont(ofSize: max(16, proseFontSize - 3), weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    static func renderEditorText(_ text: String, proseFontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: editorAttributes(proseFontSize: proseFontSize))
    }

    // MARK: - Reader rendering

    /// Compose the reader body: an optional dimmed prompt header above the
    /// rendered response. The prompt is context only and is off by default.
    static func composeReaderContent(
        promptContext: String?,
        response: String,
        showsPrompt: Bool,
        proseFontSize: CGFloat
    ) -> NSAttributedString {
        let composed = NSMutableAttributedString()
        if showsPrompt, let promptContext, !promptContext.isEmpty {
            composed.append(promptHeader(promptContext, proseFontSize: proseFontSize))
        }
        composed.append(render(response, proseFontSize: proseFontSize))
        return composed
    }

    private static func promptHeader(_ text: String, proseFontSize: CGFloat) -> NSAttributedString {
        let labelSize = max(11, proseFontSize - 11)
        let bodySize = max(14, proseFontSize - 6)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(3, bodySize * 0.18)
        paragraph.paragraphSpacing = bodySize * 0.5

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "PROMPT\n", attributes: [
            .font: NSFont.systemFont(ofSize: labelSize, weight: .heavy),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.5,
        ]))
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: bodySize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        result.append(NSAttributedString(string: "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: bodySize, weight: .regular),
        ]))
        return result
    }

    static func render(_ text: String, proseFontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(5, proseFontSize * 0.22)
        paragraph.paragraphSpacing = max(7, proseFontSize * 0.3)

        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: NSFont.systemFont(ofSize: proseFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        var insideCodeBlock = false
        var location = 0
        var rangesToRemove: [NSRange] = []
        for line in text.components(separatedBy: "\n") {
            let lineLength = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineRange = NSRange(location: location, length: lineLength)
            let isFence = trimmed.hasPrefix("```")
            if isFence {
                insideCodeBlock.toggle()
                let removalLength = location + lineLength < result.length ? lineLength + 1 : lineLength
                rangesToRemove.append(NSRange(location: location, length: removalLength))
            }

            if insideCodeBlock || isFence {
                result.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: max(16, proseFontSize - 3), weight: .medium),
                    .backgroundColor: NSColor.quaternaryLabelColor,
                ], range: lineRange)
            } else if let headingLevel = headingLevel(in: trimmed) {
                let scale = headingLevel == 1 ? 1.28 : 1.14
                result.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: proseFontSize * scale, weight: .bold),
                    range: lineRange
                )
                let leadingWhitespace = line.count - line.drop { $0.isWhitespace }.count
                rangesToRemove.append(NSRange(location: location + leadingWhitespace, length: headingLevel + 1))
            } else if isListItem(trimmed) {
                let listParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                listParagraph.firstLineHeadIndent = 0
                listParagraph.headIndent = proseFontSize * 1.15
                listParagraph.paragraphSpacing = proseFontSize * 0.45
                result.addAttribute(.paragraphStyle, value: listParagraph, range: lineRange)
            }
            location += lineLength + 1
        }

        rangesToRemove += applyLinkStyle(to: result)
        rangesToRemove += applyInlineCodeStyle(to: result, proseFontSize: proseFontSize)
        for range in rangesToRemove.sorted(by: { $0.location > $1.location }) {
            result.deleteCharacters(in: range)
        }

        return result
    }

    /// Turn `[text](url)` into clickable `text` and linkify bare URLs. Only
    /// URLs with a scheme become links; relative paths keep their text but
    /// carry no (dead) link. Returns the syntax ranges to delete.
    private static func applyLinkStyle(to result: NSMutableAttributedString) -> [NSRange] {
        var rangesToRemove: [NSRange] = []
        let string = result.string as NSString

        if let expression = try? NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)") {
            let fullRange = NSRange(location: 0, length: result.length)
            for match in expression.matches(in: result.string, range: fullRange) {
                let textRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                if let url = URL(string: string.substring(with: urlRange)), url.scheme != nil {
                    result.addAttribute(.link, value: url, range: textRange)
                }
                rangesToRemove.append(NSRange(location: match.range.location, length: 1))
                let afterText = NSMaxRange(textRange)
                rangesToRemove.append(NSRange(location: afterText, length: NSMaxRange(match.range) - afterText))
            }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let fullRange = NSRange(location: 0, length: result.length)
            for match in detector.matches(in: result.string, range: fullRange) {
                guard let url = match.url,
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }

        return rangesToRemove
    }

    private static func headingLevel(in line: String) -> Int? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...3).contains(prefix.count), line.dropFirst(prefix.count).first == " " else { return nil }
        return prefix.count
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
        guard let markerEnd = line.firstIndex(of: "."), markerEnd != line.startIndex else { return false }
        return line[..<markerEnd].allSatisfy(\.isNumber) && line.index(after: markerEnd) < line.endIndex && line[line.index(after: markerEnd)] == " "
    }

    private static func applyInlineCodeStyle(to result: NSMutableAttributedString, proseFontSize: CGFloat) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: "`[^`\\n]+`") else { return [] }
        let range = NSRange(location: 0, length: result.length)
        var delimiters: [NSRange] = []
        for match in expression.matches(in: result.string, range: range) {
            result.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(16, proseFontSize - 2), weight: .medium),
                .backgroundColor: NSColor.quaternaryLabelColor,
            ], range: match.range)
            delimiters.append(NSRange(location: match.range.location, length: 1))
            delimiters.append(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
        return delimiters
    }

    private static func panelFrame(attachedTo accessibilityFrame: CGRect) -> CGRect? {
        guard let sourceFrame = appKitFrame(fromAccessibilityFrame: accessibilityFrame) else { return nil }
        let width = min(640, max(440, sourceFrame.width * 0.42))
        let margin: CGFloat = 14
        return CGRect(
            x: sourceFrame.maxX - width - margin,
            y: sourceFrame.minY + margin,
            width: width,
            height: max(320, sourceFrame.height - margin * 2)
        )
    }

}

func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect? {
    for screen in NSScreen.screens {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        guard displayBounds.intersects(frame) else { continue }

        let x = screen.frame.minX + frame.minX - displayBounds.minX
        let distanceFromDisplayTop = frame.minY - displayBounds.minY
        let y = screen.frame.maxY - distanceFromDisplayTop - frame.height
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
    return nil
}
