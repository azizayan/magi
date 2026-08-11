import Foundation

struct ApplicationIdentity: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let name: String
}

enum SupportedApplication {
    static let desktopBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
    ]

    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.raphamorim.rio",
        "dev.commandline.waveterm",
        "org.tabby",
    ]

    static let mixedHostBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.vscodium",
        "com.codeium.windsurf",
        "com.google.antigravity",
    ]

    private static let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "kitty",
        "alacritty", "wezterm", "hyper", "rio", "wave terminal", "tabby",
    ]

    static func isSupported(bundleIdentifier: String, applicationName: String) -> Bool {
        desktopBundleIdentifiers.contains(bundleIdentifier)
            || mixedHostBundleIdentifiers.contains(bundleIdentifier)
            || isTerminal(bundleIdentifier: bundleIdentifier, applicationName: applicationName)
    }

    static func isTerminal(bundleIdentifier: String, applicationName: String) -> Bool {
        if terminalBundleIdentifiers.contains(bundleIdentifier) { return true }

        let normalizedName = applicationName.lowercased()
        if terminalNames.contains(normalizedName) { return true }

        let normalizedBundleIdentifier = bundleIdentifier.lowercased()
        return terminalNames.contains { marker in
            normalizedName.contains(marker)
                || normalizedBundleIdentifier.contains(marker.replacingOccurrences(of: " ", with: ""))
        }
    }

    static func isMixedHost(bundleIdentifier: String) -> Bool {
        mixedHostBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Direct desktop input editing is limited to the two chat applications.
    /// Mixed IDE hosts such as Cursor are supported only at a positively
    /// identified terminal surface.
    static func allowsDirectEditor(bundleIdentifier: String) -> Bool {
        desktopBundleIdentifiers.contains(bundleIdentifier)
    }

    static func allowsUniversalTerminalEditor(
        bundleIdentifier: String,
        applicationName: String,
        focusedElementHasTerminalMarker: Bool
    ) -> Bool {
        isTerminal(bundleIdentifier: bundleIdentifier, applicationName: applicationName)
            || focusedElementHasTerminalMarker
    }

    /// Accessibility elements rendered by terminal helper processes can report
    /// the helper PID rather than the owning GUI app PID. Walk upward until the
    /// first supported application is found.
    static func resolveOwner(
        startingAt processIdentifier: pid_t,
        applicationIdentity: (pid_t) -> ApplicationIdentity?,
        parentProcessIdentifier: (pid_t) -> pid_t
    ) -> ApplicationIdentity? {
        var candidate = processIdentifier
        var visited: Set<pid_t> = []
        for _ in 0..<12 {
            guard candidate > 1, visited.insert(candidate).inserted else { break }
            if let identity = applicationIdentity(candidate),
               isSupported(
                bundleIdentifier: identity.bundleIdentifier,
                applicationName: identity.name
               ) {
                return identity
            }
            candidate = parentProcessIdentifier(candidate)
        }
        return nil
    }
}
