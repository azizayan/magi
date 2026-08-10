import XCTest
@testable import OutputLens

final class ResponseBindingTests: XCTestCase {
    func testRefreshPolicyBacksOffAndStopsAfterStableContent() {
        var policy = ResponseRefreshPolicy()
        var intervals: [TimeInterval] = []

        while let interval = policy.nextInterval(contentChanged: false) {
            intervals.append(interval)
        }

        XCTAssertEqual(intervals.count, 40)
        XCTAssertEqual(Array(intervals[0..<4]), Array(repeating: 0.25, count: 4))
        XCTAssertEqual(Array(intervals[4..<8]), Array(repeating: 0.5, count: 4))
        XCTAssertEqual(Array(intervals[8..<16]), Array(repeating: 1.0, count: 8))
        XCTAssertEqual(Array(intervals[16..<40]), Array(repeating: 2.0, count: 24))
    }

    func testContentChangeAndNotificationWakeRestoreFastRefresh() {
        var policy = ResponseRefreshPolicy()
        for _ in 0..<20 {
            _ = policy.nextInterval(contentChanged: false)
        }

        XCTAssertEqual(policy.nextInterval(contentChanged: true), 0.25)
        for _ in 0..<12 {
            _ = policy.nextInterval(contentChanged: false)
        }
        policy.wake()
        XCTAssertEqual(policy.nextInterval(contentChanged: false), 0.25)
    }
}
