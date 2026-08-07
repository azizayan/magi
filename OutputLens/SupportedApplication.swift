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
        terminalBundleIdentifiers.contains(bundleIdentifier)
            || terminalNames.contains(applicationName.lowercased())
    }

    static func isMixedHost(bundleIdentifier: String) -> Bool {
        mixedHostBundleIdentifiers.contains(bundleIdentifier)
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
