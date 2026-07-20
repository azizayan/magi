import AppKit

@MainActor
final class ReaderPanelController: NSWindowController, NSWindowDelegate {
    var onUserClose: (() -> Void)?

    private let textView = NSTextView()
    private let stateLabel = NSTextField(labelWithString: "Connected")
    private let stateIndicator = NSTextField(labelWithString: "●")
    private let smallerTextButton = NSButton()
    private let largerTextButton = NSButton()
    private let closePanelButton = NSButton()
    private var lastText = ""
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
        panel.title = "Output Lens"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = Self.makeContentView(
            textView: textView,
            stateLabel: stateLabel,
            stateIndicator: stateIndicator,
            smallerTextButton: smallerTextButton,
            largerTextButton: largerTextButton,
            closePanelButton: closePanelButton
        )
        super.init(window: panel)
        panel.delegate = self
        configureHeaderButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, attachedTo accessibilityFrame: CGRect, connectionState: ConnectionState) {
        let wasNearBottom = isNearBottom
        if text != lastText {
            textView.textStorage?.setAttributedString(Self.render(text, proseFontSize: proseFontSize))
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
        lastText = message
        textView.textStorage?.setAttributedString(Self.render(message, proseFontSize: proseFontSize))
        stateLabel.stringValue = "Not connected"
        stateLabel.textColor = .systemOrange
        stateIndicator.textColor = .systemOrange
        window?.center()
        window?.orderFrontRegardless()
    }

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

    private var isNearBottom: Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return textView.bounds.maxY - visibleMaxY < 80
    }

    private func configureHeaderButtons() {
        smallerTextButton.target = self
        smallerTextButton.action = #selector(makeTextSmaller)
        smallerTextButton.toolTip = "Smaller text"

        largerTextButton.target = self
        largerTextButton.action = #selector(makeTextLarger)
        largerTextButton.toolTip = "Larger text"

        closePanelButton.target = self
        closePanelButton.action = #selector(closeFromPanel)
        closePanelButton.toolTip = "Close Output Lens"
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

    private func setProseFontSize(_ size: CGFloat) {
        guard size != proseFontSize else { return }
        proseFontSize = size
        UserDefaults.standard.set(size, forKey: "proseFontSize")
        textView.textStorage?.setAttributedString(Self.render(lastText, proseFontSize: proseFontSize))
    }

    private static func makeContentView(
        textView: NSTextView,
        stateLabel: NSTextField,
        stateIndicator: NSTextField,
        smallerTextButton: NSButton,
        largerTextButton: NSButton,
        closePanelButton: NSButton
    ) -> NSView {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        stateIndicator.font = .systemFont(ofSize: 10, weight: .bold)
        stateIndicator.textColor = .systemGreen
        stateIndicator.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        configureHeaderButton(smallerTextButton, symbol: "textformat.size.smaller", accessibilityLabel: "Smaller text")
        configureHeaderButton(largerTextButton, symbol: "textformat.size.larger", accessibilityLabel: "Larger text")
        configureHeaderButton(closePanelButton, symbol: "xmark", accessibilityLabel: "Close Output Lens")

        let controls = NSStackView(views: [smallerTextButton, largerTextButton, closePanelButton])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false

        let status = NSStackView(views: [stateIndicator, stateLabel])
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
        scrollView.documentView = textView

        effectView.addSubview(status)
        effectView.addSubview(controls)
        effectView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 28),
            controls.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
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

        rangesToRemove += applyInlineCodeStyle(to: result, proseFontSize: proseFontSize)
        for range in rangesToRemove.sorted(by: { $0.location > $1.location }) {
            result.deleteCharacters(in: range)
        }

        return result
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
