import XCTest
@testable import OutputLens

final class CLIResponseStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDecodesCodexAndClaudeCompletionPayloads() throws {
        try write([
            "type": "agent-turn-complete",
            "thread-id": "codex-session",
            "cwd": "/tmp/project",
            "last-assistant-message": "Codex exact response",
        ], name: "codex.json", date: Date(timeIntervalSince1970: 10))
        try write([
            "hook_event_name": "Stop",
            "session_id": "claude-session",
            "cwd": "/tmp/project",
            "last_assistant_message": "Claude exact response",
        ], name: "claude.json", date: Date(timeIntervalSince1970: 20))

        let records = CLIResponseStore(directory: directory).recentRecords(
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(records.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(records.map(\.sessionID), ["claude-session", "codex-session"])
    }

    func testMatchesClickedContextInsteadOfBlindlyUsingNewestResponse() throws {
        try write([
            "type": "agent-turn-complete",
            "last-assistant-message": "Older response with a distinctive clicked sentence and its conclusion.",
        ], name: "older.json", date: Date(timeIntervalSince1970: 10))
        try write([
            "type": "agent-turn-complete",
            "last-assistant-message": "Newer unrelated response that must not be selected.",
        ], name: "newer.json", date: Date(timeIntervalSince1970: 20))
        let terminal = "$ codex\nOlder response with a distinctive clicked sentence and its conclusion.\n$ "
        let clicked = (terminal as NSString).range(of: "distinctive clicked sentence").location

        let match = CLIResponseStore(directory: directory).response(
            matching: terminal,
            characterIndex: clicked,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(match?.text, "Older response with a distinctive clicked sentence and its conclusion.")
    }

    func testRejectsNewestRecordWithoutTerminalOverlap() throws {
        try write([
            "hook_event_name": "Stop",
            "last_assistant_message": "Private response from another terminal session.",
        ], name: "unrelated.json", date: Date(timeIntervalSince1970: 20))

        XCTAssertNil(CLIResponseStore(directory: directory).response(
            matching: "$ echo hello\nhello\n$ ",
            characterIndex: 15,
            now: Date(timeIntervalSince1970: 30)
        ))
    }

    func testDeletesExpiredAndExcessRecords() throws {
        try write([
            "type": "agent-turn-complete",
            "last-assistant-message": "expired response",
        ], name: "expired.json", date: Date(timeIntervalSince1970: 1))
        try write([
            "type": "agent-turn-complete",
            "last-assistant-message": "older retained response",
        ], name: "older.json", date: Date(timeIntervalSince1970: 90))
        try write([
            "type": "agent-turn-complete",
            "last-assistant-message": "newest retained response",
        ], name: "newest.json", date: Date(timeIntervalSince1970: 100))

        let records = CLIResponseStore(directory: directory, maximumFileCount: 1).recentRecords(
            now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60)
        )

        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    private func write(_ object: [String: Any], name: String, date: Date) throws {
        let url = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
