import Foundation

enum ConnectionState {
    case connected
    case paused
}

struct ResponseUpdate {
    let text: String
    let windowFrame: CGRect
    let connectionState: ConnectionState
}

@MainActor
final class ResponseBinding {
    private let snapshot: ResponseSnapshot
    private let accessibility: AccessibilityClient
    private let onUpdate: (ResponseUpdate) -> Void
    private var timer: Timer?
    private var lastText: String
    private var connectionState: ConnectionState = .connected

    init(snapshot: ResponseSnapshot, accessibility: AccessibilityClient, onUpdate: @escaping (ResponseUpdate) -> Void) {
        self.snapshot = snapshot
        self.accessibility = accessibility
        self.onUpdate = onUpdate
        self.lastText = snapshot.text

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let windowFrame = accessibility.frame(of: snapshot.windowElement),
              let nextText = accessibility.text(of: snapshot.responseElement),
              ResponseHeuristics.isSafeUpdate(previous: lastText, next: nextText) else {
            if connectionState != .paused {
                connectionState = .paused
                onUpdate(ResponseUpdate(text: lastText, windowFrame: snapshot.windowFrame, connectionState: .paused))
            }
            return
        }

        connectionState = .connected
        if nextText != lastText {
            lastText = nextText
        }
        onUpdate(ResponseUpdate(text: lastText, windowFrame: windowFrame, connectionState: .connected))
    }
}

