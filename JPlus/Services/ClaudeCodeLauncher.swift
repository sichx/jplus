#if os(macOS)
import AppKit

/// The terminal app Send to Claude opens, chosen in Settings.
enum ClaudeTerminal: String, CaseIterable, Identifiable {
    case terminal
    case iTerm

    /// App-wide, in `UserDefaults.standard`: read it with `store: .standard`,
    /// since the main window's default store is the account's own.
    static let storageKey = "claudeTerminal"
    static let standard = ClaudeTerminal.terminal

    static var current: ClaudeTerminal {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ClaudeTerminal.init) ?? standard
    }

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// AppleScript that opens a new window and runs `command` in the user's shell.
    fileprivate func script(running command: String) -> String {
        let quoted = Self.appleScriptString(command)
        switch self {
        case .terminal:
            return """
            tell application id "\(bundleID)"
                activate
                do script \(quoted)
            end tell
            """
        case .iTerm:
            return """
            tell application id "\(bundleID)"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text \(quoted)
            end tell
            """
        }
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs `claude <prompt>` in a new terminal window, in a folder the user picks.
/// JPlus is sandboxed and can't start `claude` itself, so it asks the
/// terminal app to, over Apple Events.
enum ClaudeCodeLauncher {
    /// Last folder picked, offered first next time.
    private static let lastFolderKey = "claudeLastFolder"

    enum LaunchError: LocalizedError {
        case terminalMissing(ClaudeTerminal)
        case notAllowed(ClaudeTerminal)
        case script(String)

        var errorDescription: String? {
            switch self {
            case .terminalMissing(let terminal):
                "\(terminal.title) isn't installed. Choose another terminal in JPlus Settings."
            case .notAllowed(let terminal):
                "JPlus isn't allowed to control \(terminal.title). Turn it on in System Settings › Privacy & Security › Automation › JPlus, then try again."
            case .script(let message):
                message
            }
        }
    }

    /// Asks for the folder to start in. Nil when cancelled.
    @MainActor
    static func chooseFolder(for issueKey: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Start Claude Here"
        panel.message = "Choose the folder Claude Code should work in for \(issueKey)."
        if let last = UserDefaults.standard.string(forKey: lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: lastFolderKey)
        return url
    }

    /// Opens a terminal window in `folder` running `claude "<prompt>"`. The
    /// prompt goes on the clipboard and the shell reads it with `pbpaste`:
    /// a terminal drops anything past 1024 characters typed on one line
    /// while its shell starts, which every prompt exceeds, and a temporary
    /// file would sit in JPlus's sandbox container, which macOS stops the
    /// terminal reading.
    @MainActor
    static func launch(prompt: String, in folder: URL, terminal: ClaudeTerminal = .current) throws {
        guard terminal.isInstalled else { throw LaunchError.terminalMissing(terminal) }

        Clipboard.copy(prompt)
        let command = "cd \(shellQuoted(folder.path)) && claude \"$(pbpaste)\""
        var errorInfo: NSDictionary?
        NSAppleScript(source: terminal.script(running: command))?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            // -1743: not authorized to send Apple Events; -600: app not running and couldn't launch.
            if code == -1743 { throw LaunchError.notAllowed(terminal) }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Couldn't open \(terminal.title)."
            throw LaunchError.script(message)
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
