import Foundation

struct CLIResponseRecord: Equatable {
    let provider: String
    let sessionID: String
    let workingDirectory: String
    let text: String
    let capturedAt: Date
}

final class CLIResponseStore {
    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Magi/CLI Responses", isDirectory: true)

    private let directory: URL
    private let maximumFileCount: Int
    private let maximumFileSize = 16 * 1_024 * 1_024
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    init(directory: URL = CLIResponseStore.defaultDirectory, maximumFileCount: Int = 100) {
        self.directory = directory
        self.maximumFileCount = maximumFileCount
    }

    func recentRecords(now: Date = Date()) -> [CLIResponseRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let datedURLs = urls.compactMap { url -> (URL, URLResourceValues)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return (url, values)
        }
        .sorted {
            ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast)
        }

        for (index, entry) in datedURLs.enumerated() {
            let capturedAt = entry.1.contentModificationDate ?? .distantPast
            if index >= maximumFileCount || now.timeIntervalSince(capturedAt) > maximumAge {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }

        return datedURLs.prefix(maximumFileCount).compactMap { url, values -> CLIResponseRecord? in
            guard let capturedAt = values.contentModificationDate,
                  now.timeIntervalSince(capturedAt) <= maximumAge,
                  (values.fileSize ?? maximumFileSize + 1) <= maximumFileSize,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = (payload["last-assistant-message"] as? String)
                    ?? (payload["last_assistant_message"] as? String),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let event = (payload["type"] as? String) ?? (payload["hook_event_name"] as? String) ?? ""
            let provider: String
            switch event {
            case "agent-turn-complete": provider = "codex"
            case "Stop": provider = "claude"
            default: return nil
            }
            return CLIResponseRecord(
                provider: provider,
                sessionID: (payload["thread-id"] as? String)
                    ?? (payload["session_id"] as? String)
                    ?? "",
                workingDirectory: payload["cwd"] as? String ?? "",
                text: text,
                capturedAt: capturedAt
            )
        }
    }

    func response(
        matching terminalText: String,
        characterIndex: Int?,
        now: Date = Date()
    ) -> CLIResponseRecord? {
        let terminal = Self.normalizedForMatching(terminalText)
        guard !terminal.isEmpty else { return nil }
        let context = TerminalOutputExtractor.context(
            in: terminalText,
            characterIndex: characterIndex
        ).map(Self.normalizedForMatching) ?? ""

        return recentRecords(now: now).compactMap { record -> (CLIResponseRecord, Int)? in
            let response = Self.normalizedForMatching(record.text)
            var score = 0
            if context.count >= 16, response.contains(context) {
                score = 100 + min(context.count, 500)
            }
            for probe in Self.matchingProbes(response) where terminal.contains(probe) {
                score = max(score, 40 + probe.count)
            }
            return score > 0 ? (record, score) : nil
        }
        .max { first, second in
            first.1 == second.1
                ? first.0.capturedAt < second.0.capturedAt
                : first.1 < second.1
        }?.0
    }

    private static func normalizedForMatching(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func matchingProbes(_ response: String) -> [String] {
        guard response.count >= 24 else { return [] }
        let length = min(120, response.count)
        let prefix = String(response.prefix(length))
        let suffix = String(response.suffix(length))
        return prefix == suffix ? [prefix] : [prefix, suffix]
    }
}
