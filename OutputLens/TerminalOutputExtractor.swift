import Foundation

enum TerminalOutputExtractor {
    private struct Line {
        let range: NSRange
        let text: String
    }

    static func block(in text: String, characterIndex: Int?) -> String? {
        guard let characterIndex else { return nil }
        let lines = lines(in: text)
        guard !lines.isEmpty,
              let clickedIndex = lines.firstIndex(where: {
                  NSLocationInRange(min(characterIndex, max(0, (text as NSString).length - 1)), $0.range)
              }),
              !isPrompt(lines[clickedIndex].text) else { return nil }

        let previousPrompt = lines[..<clickedIndex].lastIndex(where: { isPrompt($0.text) })
        let nextPrompt = lines[(clickedIndex + 1)...].firstIndex(where: { isPrompt($0.text) })
        guard previousPrompt != nil, nextPrompt != nil else { return nil }

        let start = previousPrompt.map { $0 + 1 } ?? 0
        let end = nextPrompt ?? lines.count
        let output = lines[start..<end]
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.count <= 500_000 else { return nil }
        return output
    }

    static func context(in text: String, characterIndex: Int?) -> String? {
        guard let characterIndex else { return nil }
        let lines = lines(in: text)
        guard !lines.isEmpty,
              let clickedIndex = lines.firstIndex(where: {
                  NSLocationInRange(min(characterIndex, max(0, (text as NSString).length - 1)), $0.range)
              }) else { return nil }

        let lower = max(0, clickedIndex - 1)
        let upper = min(lines.count, clickedIndex + 2)
        let value = lines[lower..<upper]
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func lines(in text: String) -> [Line] {
        let value = text as NSString
        guard value.length > 0 else { return [] }
        var result: [Line] = []
        var location = 0
        while location < value.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            value.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(Line(
                range: NSRange(location: start, length: max(1, end - start)),
                text: value.substring(with: NSRange(location: start, length: contentsEnd - start))
            ))
            location = max(location + 1, end)
        }
        return result
    }

    private static func isPrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let directMarkers = ["$ ", "% ", "# ", "❯ ", "➜ "]
        if directMarkers.contains(where: { trimmed.hasPrefix($0) }) { return true }

        guard let marker = trimmed.firstIndex(where: { "#$%❯➜".contains($0) }),
              trimmed.distance(from: trimmed.startIndex, to: marker) <= 80 else { return false }
        let after = trimmed.index(after: marker)
        return after < trimmed.endIndex
            && trimmed[after].isWhitespace
            && trimmed[..<marker].contains(where: { $0 == "@" || $0 == "/" || $0 == "~" })
    }
}
