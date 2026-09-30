import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                ClaudeAPIKeyEditor()
            } header: {
                Text("Draft with Claude")
            } footer: {
                Text("Used only when you press Draft with Claude on a new ticket. The screenshot and your notes are sent to Anthropic's API; the key is stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
            KeyboardShortcutsSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
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
