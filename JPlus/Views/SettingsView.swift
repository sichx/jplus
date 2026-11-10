import SwiftUI

/// The pages Settings is split into: tabs in the Mac's Settings window, a
/// list of pages on iPhone and iPad.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, ai, shortcuts

    /// The Mac Settings window's tab, kept in `UserDefaults.standard` so a
    /// button elsewhere can open Settings on the page it's about.
    static let storageKey = "settingsPage"

    /// Opens Settings on the AI page next time, such as from Enable Draft with Claude….
    static func select(_ page: SettingsPage) {
        UserDefaults.standard.set(page.rawValue, forKey: storageKey)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat.size"
        case .ai: "sparkles"
        case .shortcuts: "keyboard"
        }
    }

    /// Pages this device shows: keyboard shortcuts only where there's a keyboard.
    static var available: [SettingsPage] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom != .pad { return allCases.filter { $0 != .shortcuts } }
        #endif
        return allCases
    }
}

struct SettingsView: View {
    #if os(macOS)
    @AppStorage(SettingsPage.storageKey, store: .standard) private var page = SettingsPage.general
    #endif

    var body: some View {
        #if os(macOS)
        TabView(selection: $page) {
            ForEach(SettingsPage.available) { page in
                SettingsPageView(page: page)
                    .tabItem { Label(page.title, systemImage: page.systemImage) }
                    .tag(page)
            }
        }
        .frame(width: 520)
        #else
        Form {
            ForEach(SettingsPage.available) { page in
                NavigationLink {
                    SettingsPageView(page: page)
                        .navigationTitle(page.title)
                } label: {
                    Label(page.title, systemImage: page.systemImage)
                }
            }
        }
        #endif
    }
}

/// One page of Settings, as a grouped form.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        Form {
            switch page {
            case .general:
                IssueListsSection()
                StorageSection()
                AboutSection()
            case .appearance:
                TextSizeSection()
            case .ai:
                Section {
                    ClaudeAPIKeyEditor()
                } header: {
                    Text("Draft with Claude")
                } footer: {
                    Text(ClaudeSharing.settingsFooter)
                        .foregroundStyle(.secondary)
                }
                #if os(macOS)
                SendToAgentSection()
                #endif
            case .shortcuts:
                KeyboardShortcutsSection()
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // Each tab sizes the window to its own content.
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

/// Version, update checks and the trademark notice.
struct AboutSection: View {
    #if os(macOS)
    @Environment(AppUpdater.self) private var updater: AppUpdater?
    #endif

    var body: some View {
        Section {
            LabeledContent("Version", value: AppInfo.version)
            #if os(macOS)
            if let updater {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.checksAutomatically },
                    set: { updater.checksAutomatically = $0 }
                ))
            }
            #endif
        } header: {
            Text("About")
        } footer: {
            Text(AppInfo.trademarkNotice)
                .foregroundStyle(.secondary)
        }
    }
}

/// Font picker and size slider for the main window's text, with a sample in
/// the chosen font and size.
struct TextSizeSection: View {
    @AppStorage(TextSize.storageKey) private var step = TextSize.standardStep
    @AppStorage(AppFont.storageKey) private var appFont = AppFont.standard

    private var pointSize: Int { Int(TextSize.pointSize(forStep: step)) }
    private var scale: CGFloat { TextSize.scale(forStep: step) }

    private var footer: String {
        let standard = Int(TextSize.pointSize(forStep: TextSize.standardStep))
        let size = step == TextSize.standardStep ? "\(pointSize) pt, the standard size." : "\(pointSize) pt. The standard is \(standard) pt."
        return "\(appFont.detail) \(size)"
    }

    var body: some View {
        Section {
            Picker("Font", selection: $appFont) {
                ForEach(AppFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }

            Slider(
                value: Binding(get: { Double(TextSize.clamped(step)) }, set: { step = Int($0.rounded()) }),
                in: 0...Double(TextSize.largestStep),
                step: 1
            ) {
                Text("Size")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
                    .accessibilityLabel("Smaller")
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .accessibilityLabel("Larger")
            }
            .accessibilityValue("\(pointSize) points")

            VStack(alignment: .leading, spacing: 2) {
                Text("VPE-1234  Update the release notes")
                    .font(ScaledFont.body.font(scale: scale, family: appFont))
                Text("In Progress · updated 2 hours ago · Illegal 10 O0 l1")
                    .font(ScaledFont.caption.font(scale: scale, family: appFont))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityHidden(true)
        } header: {
            Text("Text")
        } footer: {
            Text(footer)
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether My Issues and space issue lists load resolved issues too.
struct IssueListsSection: View {
    @AppStorage(ResolvedIssues.storageKey, store: .standard) private var loadsResolved = false

    var body: some View {
        Section {
            Toggle("Load resolved issues", isOn: $loadsResolved)
        } header: {
            Text("Issue Lists")
        } footer: {
            Text("My Issues and space lists show only unresolved issues unless this is on. Either way, Done and Won't Do start unticked in a list's status filter, since some Jira sites leave done issues unresolved.")
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
/// Which coding agents a ticket's Ask AI… can start, and the terminal app
/// they run in.
struct SendToAgentSection: View {
    @AppStorage(AgentTerminal.storageKey, store: .standard) private var terminal = AgentTerminal.standard

    var body: some View {
        Section {
            ForEach(CodingAgent.allCases) { agent in
                AgentToggle(agent: agent)
            }
            Picker("Open in", selection: $terminal) {
                ForEach(AgentTerminal.allCases) { option in
                    Text(option.isInstalled ? option.title : "\(option.title) (not installed)").tag(option)
                }
            }
        } header: {
            Text("Send to Coding Agent")
        } footer: {
            Text("Adds Send to… items to a ticket's Ask AI menu. Each asks for a folder and copies the ticket's prompt. Claude and Codex then start in a new window of this terminal app, and need their command-line tools installed and on your shell's PATH. Cursor opens the folder in the Cursor app with the prompt in its chat, ready to send.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentToggle: View {
    let agent: CodingAgent
    @AppStorage private var isShown: Bool

    init(agent: CodingAgent) {
        self.agent = agent
        _isShown = AppStorage(wrappedValue: agent.showsByDefault, agent.showsKey, store: .standard)
    }

    var body: some View {
        Toggle(isOn: $isShown) {
            Text("Send to \(agent.title)")
            Text(agent.settingsDetail)
        }
    }
}
#endif

/// A shortcut as listed in Settings.
struct ShortcutInfo: Identifiable {
    /// Each key as printed on its keycap, modifiers first: ["⇧", "⌘", "O"].
    let keys: [String]
    let title: String
    var detail: String?

    var id: String { title }

    /// Add a line here when adding a shortcut.
    static let all: [ShortcutInfo] = [
        ShortcutInfo(keys: ["⌘", "K"], title: "Go to an issue or version",
                     detail: "Type a key like VPE-5555, a title or a version name"),
        ShortcutInfo(keys: ["⇧", "⌘", "O"], title: "Open the current view in Jira",
                     detail: "An issue, search, My Issues, Mentions or a version"),
        ShortcutInfo(keys: ["⌘", "+"], title: "Make text bigger", detail: "⌘= works too"),
        ShortcutInfo(keys: ["⌘", "−"], title: "Make text smaller"),
        ShortcutInfo(keys: ["⌘", "0"], title: "Make text the standard size"),
    ]
}

/// Reference list of the app's keyboard shortcuts.
struct KeyboardShortcutsSection: View {
    var body: some View {
        Section("Keyboard Shortcuts") {
            ForEach(ShortcutInfo.all) { shortcut in
                LabeledContent {
                    KeyCaps(keys: shortcut.keys)
                } label: {
                    Text(shortcut.title)
                    if let detail = shortcut.detail {
                        Text(detail)
                    }
                }
            }
        }
    }
}

/// How much the app has downloaded and cached, with a button to delete it.
struct StorageSection: View {
    @Environment(SessionStore.self) private var session
    /// Bytes on disk; nil while measuring.
    @State private var usage: Int64?
    @State private var isClearing = false
    @State private var wasCleared = false
    @State private var confirmsClear = false

    private var status: String {
        if isClearing { return "Clearing…" }
        if wasCleared { return "Cleared" }
        guard let usage else { return "Calculating…" }
        return usage == 0 ? "Nothing stored" : "Using \(usage.formatted(.byteCount(style: .file))) on \(Device.this)"
    }

    var body: some View {
        Section {
            LabeledContent {
                Button("Clear…") { confirmsClear = true }
                    .disabled(isClearing)
                    .confirmationDialog("Clear downloaded and cached data?", isPresented: $confirmsClear) {
                        Button("Clear", role: .destructive) { Task { await clear() } }
                    } message: {
                        Text("Attachments download again when you open them, and the search index is rebuilt in the background.")
                    }
            } label: {
                Text("Downloaded and cached data")
                Text(status)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Removes downloaded attachments, the search index, remembered ticket titles and cached images, for every account. Your accounts, recent tickets, search history and settings are kept.")
                .foregroundStyle(.secondary)
        }
        .task { usage = await LocalData.diskUsage() }
    }

    private func clear() async {
        isClearing = true
        await LocalData.clear(accountIDs: session.accounts.accounts.map(\.id))
        usage = await LocalData.diskUsage()
        isClearing = false
        wasCleared = true
    }
}

private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 14)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
