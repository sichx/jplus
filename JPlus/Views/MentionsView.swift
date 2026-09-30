import AppKit
import SwiftUI

/// Every @-mention of the signed-in user in descriptions and comments,
/// newest first.
struct MentionsView: View {
    let user: JiraUser
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var model = MentionsModel()

    var body: some View {
        content
            .navigationTitle("Mentions")
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .keyboardShortcut("r", modifiers: .command)
                    if let client = session.client {
                        Button("Open in Jira", systemImage: "safari") {
                            openURL(client.browseURL(jql: MentionsModel.jql))
                        }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Open these issues in Jira (⇧⌘O)")
                    }
                }
            }
            .task { if !model.hasLoaded { await reload() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.errorMessage, model.mentions.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Mentions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        } else if model.mentions.isEmpty && (model.isLoading || !model.hasLoaded) {
            ProgressView("Finding your mentions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.mentions.isEmpty {
            ContentUnavailableView("No Mentions", systemImage: "at",
                                   description: Text("Nobody has @-mentioned you in a ticket or comment yet."))
        } else {
            List {
                ForEach(groupedByDay, id: \.day) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.mentions) { mention in
                            Button {
                                onOpenIssue(mention.issueKey)
                            } label: {
                                MentionRow(mention: mention, myName: user.displayName)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(mention.issueKey)")
                            .contextMenu { menu(for: mention) }
                        }
                    }
                }
                if model.canLoadMore || model.isLoading {
                    HStack {
                        Spacer()
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Load Older Mentions") { Task { await loadMore() } }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for mention: Mention) -> some View {
        Button("Open \(mention.issueKey)") { onOpenIssue(mention.issueKey) }
        if let client = session.client {
            let url = jiraBrowseURL(for: mention, client: client)
            Button("Open in Jira") { openURL(url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Copy Key") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mention.issueKey, forType: .string)
        }
    }

    private func jiraBrowseURL(for mention: Mention, client: JiraClient) -> URL {
        var url = client.browseURL(for: mention.issueKey)
        if case .comment(let id) = mention.place {
            url.append(queryItems: [URLQueryItem(name: "focusedCommentId", value: id)])
        }
        return url
    }

    // MARK: - Grouping

    private struct DayGroup {
        let day: Date
        let mentions: [Mention]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for mention in model.mentions {
            let day = calendar.startOfDay(for: mention.date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, mentions: last.mentions + [mention])
            } else {
                groups.append(DayGroup(day: day, mentions: [mention]))
            }
        }
        return groups
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day() : .dateTime.month(.wide).day().year())
    }

    // MARK: - Loading

    private func reload() async {
        guard let client = session.client else { return }
        await model.reload(accountID: user.accountId, client: client)
    }

    private func loadMore() async {
        guard let client = session.client else { return }
        await model.loadMore(accountID: user.accountId, client: client)
    }
}

// MARK: - Row

private struct MentionRow: View {
    let mention: Mention
    let myName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: mention.author, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(mention.author?.displayName ?? "Someone").fontWeight(.semibold)
                    Text(placeText).foregroundStyle(.secondary)
                    Text(mention.issueKey).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(mention.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(mention.date.formatted(date: .complete, time: .shortened))
                }
                .font(.callout)
                .lineLimit(1)

                HStack(spacing: 6) {
                    IssueTypeBadge(name: mention.typeName, iconOnly: true).font(.caption)
                    Text(mention.issueSummary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    StatusBadge(status: mention.status).scaleEffect(0.8, anchor: .leading)
                }

                // Excerpts are already trimmed around the mention; show them whole.
                Text(highlighted(mention.excerpt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }

    private var placeText: String {
        switch mention.place {
        case .description: return "mentioned you in the description of"
        case .comment: return "mentioned you in a comment on"
        }
    }

    /// Bolds "@Your Name" in the excerpt.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = "@" + myName
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: needle, options: .caseInsensitive) {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            attributed[range].foregroundColor = .accentColor
            searchStart = range.upperBound
        }
        return attributed
    }
}
