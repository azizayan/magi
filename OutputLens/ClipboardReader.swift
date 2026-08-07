import AppKit

/// Permission-free "Copy to Magi" capture: watches the general pasteboard and
/// surfaces newly copied text. Unlike the Option-click path this needs no
/// Accessibility permission, so it is the baseline reader for users who have
/// not granted (or do not want to grant) Accessibility access.
@MainActor
final class ClipboardReader {
    var onNewText: ((String) -> Void)?
    private(set) var isWatching = false

    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private var lastChangeCount: Int
    private var timer: Timer?

    init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.35) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        // Capture the current count so pre-existing clipboard content is never
        // shown automatically — only text copied after watching starts.
        self.lastChangeCount = pasteboard.changeCount
    }

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.checkForChange()
            }
        }
    }

    func stopWatching() {
        isWatching = false
        timer?.invalidate()
        timer = nil
    }

    /// Explicit "Paste now" capture, independent of the watch state.
    func captureNow() {
        lastChangeCount = pasteboard.changeCount
        surfaceCurrentText()
    }

    /// Mark a clipboard write performed by Magi itself as already observed.
    /// This keeps the terminal editor's paste handoff from replacing its own
    /// draft with a clipboard Reader session on the next polling tick.
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Core poll step. Returns the surfaced text when a new copy is detected,
    /// otherwise nil. Exposed for testing; the timer calls it on a schedule.
    @discardableResult
    func checkForChange() -> String? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        return surfaceCurrentText()
    }

    @discardableResult
    private func surfaceCurrentText() -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        onNewText?(text)
        return text
    }
}
