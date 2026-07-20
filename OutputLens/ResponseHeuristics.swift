import ApplicationServices

struct ResponseTextFragment {
    let text: String
    let frame: CGRect?
    let role: String
}

struct ResponseCandidate {
    let element: AXUIElement
    let depth: Int
    let role: String
    let description: String
    let text: String
    let actionNames: [String]
}

enum ResponseHeuristics {
    static func assemble(_ fragments: [ResponseTextFragment]) -> String {
        var unique: [ResponseTextFragment] = []
        for fragment in fragments {
            if let last = unique.last, last.text == fragment.text {
                if last.role == (kAXHeadingRole as String), fragment.role != (kAXHeadingRole as String) {
                    unique[unique.count - 1] = fragment
                }
                continue
            }
            unique.append(fragment)
        }
        guard let first = unique.first else { return "" }

        var result = semanticText(for: first)
        for pair in zip(unique, unique.dropFirst()) {
            let previous = pair.0
            let next = pair.1
            result += separator(between: previous, and: next)
            result += semanticText(for: next)
        }
        return normalize(result)
    }

    static func selectCandidate(_ candidates: [ResponseCandidate]) -> ResponseCandidate? {
        let readable = candidates.filter { !$0.text.isEmpty && $0.text.count <= 100_000 }
        if let responseIndex = readable.firstIndex(where: { hasResponseControls($0.actionNames) }) {
            let responseContainer = readable[responseIndex]
            let child = responseIndex > 0 ? readable[responseIndex - 1] : nil
            if !isConversationContainer(responseContainer, comparedTo: child) {
                return responseContainer
            }
        }
        guard var selected = readable.first else { return nil }

        for candidate in readable.dropFirst() {
            guard candidate.text.count >= selected.text.count else { continue }

            let expansion = candidate.text.count - selected.text.count
            let isConversationSizedJump = selected.text.count >= 40 &&
                candidate.text.count > selected.text.count * 3 &&
                expansion > 500

            if isConversationSizedJump {
                break
            }

            selected = candidate
        }
        return selected
    }

    private static func isConversationContainer(_ candidate: ResponseCandidate, comparedTo child: ResponseCandidate?) -> Bool {
        guard let child, candidate.actionNames.count > 12 else { return false }
        return child.text.count >= 40 &&
            candidate.text.count > child.text.count * 3 &&
            candidate.text.count - child.text.count > 500
    }

    static func hasResponseControls(_ actionNames: [String]) -> Bool {
        actionNames.contains { name in
            let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == "copy" ||
                normalized == "show message actions" ||
                normalized.contains("copy response") ||
                normalized.contains("copy message") ||
                normalized.contains("good response") ||
                normalized.contains("bad response") ||
                normalized.contains("thumbs up") ||
                normalized.contains("thumbs down")
        }
    }

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSafeUpdate(previous: String, next: String) -> Bool {
        guard !next.isEmpty else { return false }
        guard !previous.isEmpty else { return true }
        if next.hasPrefix(previous) || previous.hasPrefix(next) { return true }

        let fingerprintLength = min(80, previous.count, next.count)
        guard fingerprintLength >= 20 else { return false }
        return previous.prefix(fingerprintLength) == next.prefix(fingerprintLength)
    }

    private static func separator(between previous: ResponseTextFragment, and next: ResponseTextFragment) -> String {
        if previous.text.last?.isWhitespace == true || next.text.first?.isWhitespace == true {
            return ""
        }

        guard let previousFrame = previous.frame, let nextFrame = next.frame else {
            return "\n"
        }

        let overlap = min(previousFrame.maxY, nextFrame.maxY) - max(previousFrame.minY, nextFrame.minY)
        let sameLine = overlap > min(previousFrame.height, nextFrame.height) * 0.45
        guard sameLine else { return "\n" }

        if let first = next.text.first, ".,;:!?)]}".contains(first) {
            return ""
        }
        if let last = previous.text.last, "([{<".contains(last) {
            return ""
        }
        return " "
    }

    private static func semanticText(for fragment: ResponseTextFragment) -> String {
        guard fragment.role == (kAXHeadingRole as String), !fragment.text.hasPrefix("#") else {
            return fragment.text
        }
        return "## \(fragment.text)"
    }
}
