import Foundation
import ApplicationServices

enum ConnectionState {
    case connected
    case paused
    case captured
}

struct ResponseUpdate {
    let text: String
    let promptContext: String?
    let windowFrame: CGRect
    let connectionState: ConnectionState
}

struct ResponseRefreshPolicy {
    private(set) var unchangedRefreshCount = 0

    mutating func nextInterval(contentChanged: Bool) -> TimeInterval? {
        if contentChanged {
            unchangedRefreshCount = 0
            return 0.25
        }
        unchangedRefreshCount += 1
        switch unchangedRefreshCount {
        case 1...4: return 0.25
        case 5...8: return 0.5
        case 9...16: return 1
        case 17...40: return 2
        default: return nil
        }
    }

    mutating func wake() {
        unchangedRefreshCount = 0
    }
}

private func responseBindingAXCallback(
    _: AXObserver,
    _: AXUIElement,
    _: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let binding = Unmanaged<ResponseBinding>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        binding.sourceDidChange()
    }
}

@MainActor
final class ResponseBinding {
    private var snapshot: ResponseSnapshot
    private let accessibility: AccessibilityClient
    private let onUpdate: (ResponseUpdate) -> Void
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedNotifications: [CFString] = []
    private var lastText: String
    private var connectionState: ConnectionState = .connected
    private var refreshPolicy = ResponseRefreshPolicy()

    init(snapshot: ResponseSnapshot, accessibility: AccessibilityClient, onUpdate: @escaping (ResponseUpdate) -> Void) {
        self.snapshot = snapshot
        self.accessibility = accessibility
        self.onUpdate = onUpdate
        self.lastText = snapshot.text

        installObserver()
        scheduleRefresh(after: 0.25)
    }

    private func scheduleRefresh(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func installObserver() {
        var createdObserver: AXObserver?
        guard AXObserverCreate(snapshot.applicationPID, responseBindingAXCallback, &createdObserver) == .success,
              let createdObserver else { return }

        let notifications: [CFString] = [
            kAXValueChangedNotification as CFString,
            kAXLayoutChangedNotification as CFString,
            "AXChildrenChanged" as CFString,
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications where AXObserverAddNotification(
            createdObserver,
            snapshot.containerElement,
            notification,
            refcon
        ) == .success {
            observedNotifications.append(notification)
        }
        guard !observedNotifications.isEmpty else { return }
        observer = createdObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        if let observer {
            for notification in observedNotifications {
                AXObserverRemoveNotification(observer, snapshot.containerElement, notification)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedNotifications.removeAll()
    }

    func sourceDidChange() {
        refreshPolicy.wake()
        scheduleRefresh(after: 0.1)
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
            if let interval = refreshPolicy.nextInterval(contentChanged: false) {
                scheduleRefresh(after: interval)
            } else {
                timer = nil
            }
            return
        }

        let contentChanged = resolution.text != lastText
        let presentationChanged = contentChanged
            || resolution.promptContext != nil && resolution.promptContext != snapshot.promptContext
            || windowFrame != snapshot.windowFrame
            || connectionState != .connected
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
        if presentationChanged {
            onUpdate(ResponseUpdate(text: lastText, promptContext: snapshot.promptContext, windowFrame: windowFrame, connectionState: .connected))
        }
        if let interval = refreshPolicy.nextInterval(contentChanged: contentChanged) {
            scheduleRefresh(after: interval)
        } else {
            timer = nil
        }
    }
}
