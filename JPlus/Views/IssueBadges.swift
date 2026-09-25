import SwiftUI

struct PersonCell: View {
    let user: JiraUser?
    var avatarSize: CGFloat = 18

    var body: some View {
        if let user {
            HStack(spacing: 6) {
                AvatarView(user: user, size: avatarSize)
                Text(user.displayName).lineLimit(1)
            }
        } else {
            Text("Unassigned").foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: JiraIssue.Status

    private var color: Color {
        switch status.statusCategory?.key {
        case "done": return .green
        case "indeterminate": return .blue
        default: return .gray
        }
    }

    var body: some View {
        Text(status.name.uppercased())
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

struct IssueTypeBadge: View {
    let name: String
    var iconOnly = false

    private var symbol: (String, Color) {
        switch name.lowercased() {
        case "bug": return ("ladybug.fill", .red)
        case "story": return ("bookmark.fill", .green)
        case "task": return ("checkmark.square.fill", .blue)
        case "epic": return ("bolt.fill", .purple)
        case "sub-task", "subtask": return ("arrow.turn.down.right", .blue)
        default: return ("doc.text.fill", .secondary)
        }
    }

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: symbol.0)
            } else {
                Label(name, systemImage: symbol.0)
            }
        }
        .font(.callout)
        .foregroundStyle(symbol.1)
        .help(name)
    }
}

struct PriorityLabel: View {
    let name: String

    private var symbol: (String, Color) {
        switch name.lowercased() {
        case "highest", "blocker", "critical": return ("chevron.up.2", .red)
        case "high", "major": return ("chevron.up", .orange)
        case "medium": return ("equal", .orange)
        case "low", "minor": return ("chevron.down", .blue)
        case "lowest", "trivial": return ("chevron.down.2", .blue)
        default: return ("minus", .secondary)
        }
    }

    var body: some View {
        Label(name, systemImage: symbol.0).foregroundStyle(symbol.1)
    }
}

struct TagList: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
