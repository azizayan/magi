import Foundation

enum ConnectionState {
    case connected
    case paused
}

struct ResponseUpdate {
    let text: String
    let promptContext: String?
    let windowFrame: CGRect
    let connectionState: ConnectionState
}

@MainActor
final class ResponseBinding {
    private var snapshot: ResponseSnapshot
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
              let resolution = accessibility.refreshResponse(snapshot, previousText: lastText) else {
            // Identity lost: pause on the last confirmed text instead of
            // expanding to a parent conversation.
            if connectionState != .paused {
                connectionState = .paused
                onUpdate(ResponseUpdate(text: lastText, promptContext: snapshot.promptContext, windowFrame: snapshot.windowFrame, connectionState: .paused))
            }
            return
        }

        connectionState = .connected
        lastText = resolution.text
        snapshot = ResponseSnapshot(
            applicationPID: snapshot.applicationPID,
            containerElement: snapshot.containerElement,
            windowElement: snapshot.windowElement,
            adapter: snapshot.adapter,
            sectionIndex: resolution.sectionIndex,
            text: resolution.text,
            promptContext: resolution.promptContext ?? snapshot.promptContext,
            responseFrame: resolution.frame ?? snapshot.responseFrame,
            windowFrame: windowFrame
        )
        onUpdate(ResponseUpdate(text: lastText, promptContext: snapshot.promptContext, windowFrame: windowFrame, connectionState: .connected))
    }
}
