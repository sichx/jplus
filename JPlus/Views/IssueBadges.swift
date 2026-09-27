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
        FlowLayout(spacing: 6) {
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

/// Lays children out left to right, wrapping onto new lines when out of room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
