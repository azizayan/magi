import AppKit

@MainActor
final class SourceHighlightController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func flash(responseFrame: CGRect, inside windowFrame: CGRect) {
        let visibleFrame = responseFrame.intersection(windowFrame)
        guard !visibleFrame.isNull,
              visibleFrame.width > 20,
              visibleFrame.height > 20,
              let frame = appKitFrame(fromAccessibilityFrame: visibleFrame) else { return }

        hide()

        let panel = NSPanel(
            contentRect: frame.insetBy(dx: -5, dy: -5),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]

        let outline = NSView()
        outline.wantsLayer = true
        outline.layer?.cornerRadius = 12
        outline.layer?.borderWidth = 3
        outline.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        panel.contentView = outline
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self.panel === panel {
                        panel.orderOut(nil)
                        self.panel = nil
                    }
                }
            })
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
