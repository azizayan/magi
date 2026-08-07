import Foundation

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

    private static let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "kitty",
        "alacritty", "wezterm", "hyper", "rio", "wave terminal", "tabby",
    ]

    static func isSupported(bundleIdentifier: String, applicationName: String) -> Bool {
        desktopBundleIdentifiers.contains(bundleIdentifier)
            || isTerminal(bundleIdentifier: bundleIdentifier, applicationName: applicationName)
    }

    static func isTerminal(bundleIdentifier: String, applicationName: String) -> Bool {
        terminalBundleIdentifiers.contains(bundleIdentifier)
            || terminalNames.contains(applicationName.lowercased())
    }
}
