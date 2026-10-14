import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            TextSizeSection()
            Section {
                GitHubConnectionEditor()
            } header: {
                Text("GitHub · Create Branch")
            } footer: {
                Text("The connection is saved for the current Jira account. Tokens are stored in the Keychain.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ClaudeAPIKeyEditor()
            } header: {
                Text("Draft with Claude")
            } footer: {
                Text(ClaudeSharing.settingsFooter)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            KeyboardShortcutsSection()
            #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                KeyboardShortcutsSection()
            }
            #endif
            StorageSection()
            Section {
                LabeledContent("Version", value: AppInfo.version)
            } header: {
                Text("About")
            } footer: {
                Text(AppInfo.trademarkNotice)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 480)
        #endif
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
