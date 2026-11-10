#if os(macOS)
import AppKit

/// A coding agent that Ask AI can start with a ticket's prompt: Send to
/// Claude…, Send to Codex… (their command-line tools, in a terminal) and Send
/// to Cursor… (the Cursor app, with the prompt in its chat).
enum CodingAgent: String, CaseIterable, Identifiable {
    case claude
    case codex
    case cursor

    var id: String { rawValue }

    /// "Claude", as in Send to Claude….
    nonisolated var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// The tool that has to be installed, named as its makers do.
    nonisolated var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .cursor: "Cursor"
        }
    }

    /// Runs in a terminal, as opposed to Cursor, which opens its own app.
    var usesTerminal: Bool { self != .cursor }

    /// The command that starts an interactive session with a first prompt,
    /// for the agents that run in a terminal: `claude "…"`, `codex "…"`.
    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        }
    }

    /// How Settings describes what Send to… does.
    var settingsDetail: String {
        usesTerminal
            ? "Runs \(command) from \(productName) in a terminal"
            : "Opens the folder in the Cursor app and fills its chat with the prompt"
    }

    nonisolated var installURL: String {
        switch self {
        case .claude: "https://claude.com/claude-code"
        case .codex: "https://developers.openai.com/codex/cli"
        case .cursor: "https://cursor.com/download"
        }
    }

    /// Whether Ask AI… lists this agent, set in Settings › AI. Claude is on
    /// until turned off; the others are off until turned on.
    var showsKey: String { "showsSendTo.\(rawValue)" }
    var showsByDefault: Bool { self == .claude }
}

/// The terminal app Send to… opens, chosen in Settings.
enum AgentTerminal: String, CaseIterable, Identifiable {
    case terminal
    case iTerm

    /// App-wide, in `UserDefaults.standard`: read it with `store: .standard`,
    /// since the main window's default store is the account's own.
    static let storageKey = "claudeTerminal"
    static let standard = AgentTerminal.terminal

    static var current: AgentTerminal {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AgentTerminal.init) ?? standard
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

/// Runs an agent's command with a prompt in a new terminal window, in a
/// folder the user picks. JPlus is sandboxed and can't start the command
/// itself, so it asks the terminal app to, over Apple Events.
enum AgentLauncher {
    /// Last folder picked, offered first next time. Shared by every agent.
    private static let lastFolderKey = "claudeLastFolder"

    /// What Send to… did, when it worked.
    enum Outcome {
        /// The agent has the prompt.
        case sent
        /// The prompt is on the clipboard for pasting, as it was too long to send.
        case promptCopied(reason: String)
    }

    enum LaunchError: LocalizedError {
        case terminalMissing(AgentTerminal)
        case notAllowed(AgentTerminal)
        case script(String)
        case cursorMissing
        case cursorOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .cursorMissing:
                "The Cursor app isn't installed. Get it at \(CodingAgent.cursor.installURL)."
            case .cursorOpenFailed(let message):
                "Couldn't open the folder in Cursor. \(message)"
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
    static func chooseFolder(for issueKey: String, agent: CodingAgent) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = agent.usesTerminal ? "Start \(agent.title) Here" : "Open in \(agent.title)"
        panel.message = "Choose the folder \(agent.productName) should work in for \(issueKey)."
        if let last = UserDefaults.standard.string(forKey: lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: lastFolderKey)
        return url
    }

    /// Starts `agent` with `prompt`, working in `folder`.
    @MainActor
    static func launch(_ agent: CodingAgent, prompt: String, in folder: URL) async throws -> Outcome {
        if agent.usesTerminal {
            try launchInTerminal(agent, prompt: prompt, in: folder)
            return .sent
        }
        return try await openInCursor(prompt: prompt, folder: folder)
    }

    // MARK: - Cursor

    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    /// Cursor's documented maximum for a deeplink, encoded.
    private static let cursorLinkLimit = 10_000

    /// Opens `folder` in the Cursor app, then a prompt deeplink that fills its
    /// chat with `prompt` for the user to review and send. Cursor's CLI agent
    /// keeps its chats apart from the app's, so this uses the app itself.
    /// The prompt is copied too, in case the link doesn't reach the chat; a
    /// prompt too long for a link is only copied, for pasting.
    @MainActor
    private static func openInCursor(prompt: String, folder: URL) async throws -> Outcome {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID) else {
            throw LaunchError.cursorMissing
        }
        Clipboard.copy(prompt)
        do {
            try await NSWorkspace.shared.open([folder], withApplicationAt: appURL,
                                              configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw LaunchError.cursorOpenFailed(error.localizedDescription)
        }

        guard let link = cursorPromptLink(prompt), link.absoluteString.count <= cursorLinkLimit else {
            return .promptCopied(reason: "This ticket's prompt is longer than Cursor's links allow, so it's on the clipboard instead. Paste it into Cursor's chat.")
        }
        // Give the folder's window a moment to open and come to the front,
        // so the prompt lands in its chat rather than another window's.
        try? await Task.sleep(for: .seconds(1.5))
        NSWorkspace.shared.open(link)
        return .sent
    }

    /// `cursor://anysphere.cursor-deeplink/prompt?text=…`, with everything but
    /// unreserved characters percent-encoded: Cursor misreads a bare `&` or `+`.
    private static func cursorPromptLink(_ prompt: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let text = prompt.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "cursor://anysphere.cursor-deeplink/prompt?text=\(text)")
    }

    // MARK: - Terminal

    /// Opens a terminal window in `folder` running `<command> "<prompt>"`, or
    /// saying where to get the tool when the command isn't found. The
    /// prompt goes on the clipboard and the shell reads it with `pbpaste`:
    /// a terminal drops anything past 1024 characters typed on one line
    /// while its shell starts, which every prompt exceeds, and a temporary
    /// file would sit in JPlus's sandbox container, which macOS stops the
    /// terminal reading.
    @MainActor
    private static func launchInTerminal(_ agent: CodingAgent, prompt: String, in folder: URL,
                                         terminal: AgentTerminal = .current) throws {
        guard terminal.isInstalled else { throw LaunchError.terminalMissing(terminal) }

        Clipboard.copy(prompt)
        // Two checks rather than `a && b || c`, so the message can't follow a
        // session that merely exited with an error. Works in zsh, bash and fish.
        let found = "command -v \(agent.command) >/dev/null"
        let missing = shellQuoted("\(agent.productName) (\(agent.command)) isn't installed or isn't on your PATH. Get it at \(agent.installURL)")
        let command = "cd \(shellQuoted(folder.path)); \(found) || echo \(missing); \(found) && \(agent.command) \"$(pbpaste)\""
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
