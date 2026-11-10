import SwiftUI

/// Sendable column sort for issue tables (Swift 6–safe alternative to `KeyPathComparator` in `@State`).
struct IssueSummarySortComparator: SortComparator, Hashable, Sendable {
    enum Column: Hashable, Sendable {
        case issueType, key, summary, status, assignee, updated
    }

    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: IssueSummary, _ rhs: IssueSummary) -> ComparisonResult {
        switch column {
        case .issueType:
            lhs.fields.issueType.name.localizedStandardCompare(rhs.fields.issueType.name)
        case .key:
            lhs.key.localizedStandardCompare(rhs.key)
        case .summary:
            lhs.fields.summary.localizedStandardCompare(rhs.fields.summary)
        case .status:
            lhs.fields.status.name.localizedStandardCompare(rhs.fields.status.name)
        case .assignee:
            (lhs.fields.assignee?.displayName ?? "").localizedStandardCompare(rhs.fields.assignee?.displayName ?? "")
        case .updated:
            lhs.fields.updated.compare(rhs.fields.updated)
        }
    }

    /// `sorted(using:)` only applies `order` for `KeyPathComparator`; custom comparators must flip here.
    func orders(_ lhs: IssueSummary, before rhs: IssueSummary) -> Bool {
        switch order {
        case .forward:
            compare(lhs, rhs) == .orderedAscending
        case .reverse:
            compare(lhs, rhs) == .orderedDescending
        }
    }
}

/// Table of issues with double-click to open. Shared by search and versions.
/// Where the width is compact (an iPhone), a list of stacked rows instead,
/// since a table there shows only its first column.
struct IssueListView<FilterAccessory: View>: View {
    let issues: [IssueSummary]
    let onOpen: (String) -> Void
    /// Controls shown to the left of the filter field, such as a status toggle.
    let filterAccessory: FilterAccessory
    /// Whether statuses in Jira's Done category (Done, Won't Do) start
    /// unticked in the status filter. Off where the screen has its own
    /// control for done issues.
    let hidesDoneByDefault: Bool

    /// - Parameter statusFilterKey: Names this list for saving which statuses
    ///   are ticked, so the choice survives reloads and relaunches. Saved per
    ///   account, as each Jira site has its own statuses.
    init(issues: [IssueSummary], onOpen: @escaping (String) -> Void, statusFilterKey: String,
         hidesDoneByDefault: Bool = true,
         @ViewBuilder filterAccessory: () -> FilterAccessory) {
        self.issues = issues
        self.onOpen = onOpen
        self.hidesDoneByDefault = hidesDoneByDefault
        _savedStatusChoices = AppStorage(wrappedValue: "", "statusFilter.\(statusFilterKey)")
        self.filterAccessory = filterAccessory()
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont
    @State private var selection: Set<IssueSummary.ID> = []
    @State private var sortOrder = [IssueSummarySortComparator(column: .updated, order: .reverse)]
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    /// Statuses ticked or unticked in the status filter, by name. A status
    /// not in here is shown unless it's a done one and those start hidden,
    /// so a status that turns up later follows that default.
    /// `statusChoices` as JSON, in the account's settings.
    @AppStorage private var savedStatusChoices: String

    private var statusChoices: [String: Bool] {
        get {
            (try? JSONDecoder().decode([String: Bool].self, from: Data(savedStatusChoices.utf8))) ?? [:]
        }
        nonmutating set {
            savedStatusChoices = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
    @State private var isPickingStatuses = false
    /// Issues whose status or assignee was changed from the context menu,
    /// shown changed until the list is loaded again. Keyed by issue key.
    @State private var changedIssues: [String: IssueSummary] = [:]
    @State private var editing: ListEdit?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    private var filterExpanded: Bool {
        filterFocused || !filterText.isEmpty
    }

    private var currentIssues: [IssueSummary] {
        changedIssues.isEmpty ? issues : issues.map { changedIssues[$0.key] ?? $0 }
    }

    private var filteredIssues: [IssueSummary] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = activeHiddenStatuses
        guard !needle.isEmpty || !hidden.isEmpty else { return currentIssues }
        return currentIssues.filter {
            !hidden.contains($0.fields.status.name) && (needle.isEmpty || $0.matchesLocalFilter(needle))
        }
    }

    private func isShown(_ status: JiraIssue.Status, choices: [String: Bool]? = nil) -> Bool {
        (choices ?? statusChoices)[status.name] ?? !(hidesDoneByDefault && status.isDone)
    }

    /// Each status in the list with how many issues have it, ordered by
    /// Jira's category (to do, in progress, done) and then by name.
    private var statusCounts: [(status: JiraIssue.Status, count: Int)] {
        var counts: [String: (status: JiraIssue.Status, count: Int)] = [:]
        for issue in currentIssues {
            let status = issue.fields.status
            counts[status.name, default: (status, 0)].count += 1
        }
        func rank(_ status: JiraIssue.Status) -> Int {
            switch status.statusCategory?.key {
            case "new": 0
            case "indeterminate": 1
            case "done": 2
            default: 1
            }
        }
        return counts.values.sorted {
            let (l, r) = (rank($0.status), rank($1.status))
            return l != r ? l < r : $0.status.name.localizedStandardCompare($1.status.name) == .orderedAscending
        }
    }

    /// Hidden statuses that some issue in the list actually has.
    private var activeHiddenStatuses: Set<String> {
        let choices = statusChoices
        return Set(currentIssues.lazy.map(\.fields.status).filter { !isShown($0, choices: choices) }.map(\.name))
    }

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !activeHiddenStatuses.isEmpty
    }

    /// `Table`'s `sortOrder` binding drives header indicators and clicks; row order must be applied locally.
    private var displayedIssues: [IssueSummary] {
        guard let active = sortOrder.first else { return filteredIssues }
        return filteredIssues.sorted { active.orders($0, before: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCompact { compactAccessoryRow }
            filterBar
            Divider()
            Group {
                if isCompact {
                    issueRows
                } else {
                    issueTable
                }
            }
            .overlay {
                if displayedIssues.isEmpty, !currentIssues.isEmpty {
                    Text(filterText.isEmpty ? "All \(currentIssues.count) issues are hidden by the status filter."
                                            : "No issues match the filter.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: issues) { changedIssues = [:] }
        .sheet(item: $editing) { edit in
            ListEditSheet(edit: edit, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { changed in
                changedIssues[changed.key] = changed
            }
            .environment(session)
        }
    }

    /// On an iPhone the accessory controls get a row of their own, scrolling
    /// sideways if they don't fit, so the filter bar never runs off screen.
    @ViewBuilder
    private var compactAccessoryRow: some View {
        if FilterAccessory.self != EmptyView.self {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) { filterAccessory }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .scaledFont(.subheadline)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            if !filterExpanded && !isCompact { Spacer(minLength: 0) }

            if !isCompact { filterAccessory }

            if isCompact && !filterExpanded {
                sortMenu
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText, prompt: Text("Filter this list"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                        filterFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.controlBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(filterFocused ? 0.45 : 0.22))
            )
            .frame(maxWidth: filterExpanded || isCompact ? .infinity : 200)

            statusFilterButton

            if isFiltering {
                Text("\(displayedIssues.count) of \(issues.count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.22), value: filterExpanded)
    }

    /// Opens a list of checkboxes, one per status in the list, to choose
    /// which statuses show.
    private var statusFilterButton: some View {
        let hiddenCount = activeHiddenStatuses.count
        return Button {
            isPickingStatuses.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hiddenCount > 0
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                if !isCompact { Text("Status") }
                if hiddenCount > 0 {
                    Text("\(statusCounts.count - hiddenCount)/\(statusCounts.count)")
                        .scaledFont(.caption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(hiddenCount > 0 ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(statusCounts.isEmpty)
        .help("Filter by status")
        .accessibilityLabel("Filter by status")
        .popover(isPresented: $isPickingStatuses, arrowEdge: .bottom) {
            statusChecklist
                .presentationCompactAdaptation(.popover)
        }
    }

    private var statusChecklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(statusCounts, id: \.status.name) { entry in
                let name = entry.status.name
                let shown = isShown(entry.status)
                Button {
                    statusChoices[name] = !shown
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: shown ? "checkmark.square.fill" : "square")
                            .foregroundStyle(shown ? Color.accentColor : Color.secondary)
                        StatusBadge(status: entry.status)
                        Spacer(minLength: 12)
                        Text("\(entry.count)")
                            .scaledFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shown ? .isSelected : [])
            }
            Divider().padding(.vertical, 6)
            HStack {
                Button("Show All") {
                    var choices = statusChoices
                    for entry in statusCounts { choices[entry.status.name] = true }
                    statusChoices = choices
                }
                .disabled(activeHiddenStatuses.isEmpty)
                Spacer()
                Button("Hide Done") {
                    var choices = statusChoices
                    for entry in statusCounts where entry.status.isDone { choices[entry.status.name] = false }
                    statusChoices = choices
                }
                .disabled(!statusCounts.contains { $0.status.isDone && isShown($0.status) })
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    /// Widths of the columns around Summary, each fitted to its widest cell
    /// (or header) in the rows on screen, so Summary takes whatever is left
    /// however the window is sized.
    private struct ColumnWidths {
        var key: CGFloat = 0
        var status: CGFloat = 0
        var assignee: CGFloat = 0
        var updated: CGFloat = 0
    }

    private var columnWidths: ColumnWidths {
        /// Space a table cell adds around its content.
        let cellInset: CGFloat = 16
        /// A header's title plus its sort indicator.
        let headerFont = PlatformFont.systemFont(ofSize: PlatformFont.smallSystemFontSize, weight: .medium)
        let sortIndicatorWidth: CGFloat = 18
        let issues = displayedIssues
        func fitted(_ header: String, _ widths: [CGFloat]) -> CGFloat {
            let title = ceil((header as NSString).size(withAttributes: [.font: headerFont]).width) + sortIndicatorWidth
            return max(title, widths.max() ?? 0) + cellInset
        }
        let body = ScaledFont.body
        let badge = ScaledFont.caption.weight(.bold)
        var widths = ColumnWidths()
        widths.key = fitted("Key", issues.map { body.monospaced().width(of: $0.key, scale: textScale, family: appFont) })
        widths.status = fitted("Status", Set(issues.map { $0.fields.status.name.uppercased() }).map {
            badge.width(of: $0, scale: textScale, family: appFont) + 16
        })
        widths.assignee = fitted("Assignee", issues.map { issue in
            if let assignee = issue.fields.assignee {
                return 18 + 6 + body.width(of: assignee.displayName, scale: textScale, family: appFont)
            }
            return body.width(of: "Unassigned", scale: textScale, family: appFont)
        })
        widths.updated = fitted("Updated", Set(issues.map { $0.fields.updated.formatted(.relative(presentation: .named)) }).map {
            body.width(of: $0, scale: textScale, family: appFont)
        })
        return widths
    }

    private var issueTable: some View {
        let widths = columnWidths
        return Table(displayedIssues, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", sortUsing: IssueSummarySortComparator(column: .issueType)) { issue in
                IssueTypeBadge(name: issue.fields.issueType.name, iconOnly: true)
            }
            // Every column but Summary fits its contents; Summary takes what's left.
            .width(24 * textScale)

            TableColumn("Key", sortUsing: IssueSummarySortComparator(column: .key)) { issue in
                // The system mono font whatever Settings › Font says, as the width above assumes.
                Text(issue.key).scaledFont(.body.monospaced())
            }
            .width(widths.key)

            TableColumn("Summary", sortUsing: IssueSummarySortComparator(column: .summary)) { issue in
                Text(issue.fields.summary).lineLimit(1).help(issue.fields.summary)
            }

            TableColumn("Status", sortUsing: IssueSummarySortComparator(column: .status)) { issue in
                StatusBadge(status: issue.fields.status)
            }
            .width(widths.status)

            TableColumn("Assignee", sortUsing: IssueSummarySortComparator(column: .assignee)) { issue in
                PersonCell(user: issue.fields.assignee)
            }
            .width(widths.assignee)

            TableColumn("Updated", sortUsing: IssueSummarySortComparator(column: .updated)) { issue in
                Text(issue.fields.updated, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .help(issue.fields.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .width(widths.updated)
        }
        .contextMenu(forSelectionType: IssueSummary.ID.self) { ids in
            if let issue = issue(for: ids) {
                let key = issue.key
                Button("Open \(key)") { onOpen(key) }
                Divider()
                editActions(for: issue)
                Divider()
                if let client = session.client {
                    let url = client.browseURL(for: key)
                    Button("Open in Jira") { openURL(url) }
                    Button("Copy URL") {
                        Clipboard.copy(url.absoluteString)
                    }
                }
                Button("Copy Key") {
                    Clipboard.copy(key)
                }
            }
        } primaryAction: { ids in
            if let issue = issue(for: ids) { onOpen(issue.key) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact

    private static var sortColumns: [(IssueSummarySortComparator.Column, String)] { [
        (.updated, "Updated"), (.key, "Key"), (.summary, "Summary"),
        (.status, "Status"), (.assignee, "Assignee"), (.issueType, "Type"),
    ] }

    /// The table's header clicks, as a menu: pick a column, or the current
    /// one again to flip the order.
    private var sortMenu: some View {
        Menu {
            ForEach(Self.sortColumns, id: \.0) { column, title in
                let active = sortOrder.first
                Button {
                    if active?.column == column {
                        sortOrder = [IssueSummarySortComparator(column: column, order: active?.order == .forward ? .reverse : .forward)]
                    } else {
                        // Newest first for dates; A to Z for everything else.
                        sortOrder = [IssueSummarySortComparator(column: column, order: column == .updated ? .reverse : .forward)]
                    }
                } label: {
                    if active?.column == column {
                        Label(title, systemImage: active?.order == .forward ? "chevron.up" : "chevron.down")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .padding(6)
        }
        .accessibilityLabel("Sort")
    }

    private var issueRows: some View {
        List(displayedIssues) { issue in
            Button { onOpen(issue.key) } label: {
                CompactIssueRow(issue: issue)
            }
            .foregroundStyle(.primary)
            .contextMenu {
                editActions(for: issue)
                Divider()
                rowActions(for: issue.key)
            }
        }
        .listStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowActions(for key: String) -> some View {
        if let client = session.client {
            let url = client.browseURL(for: key)
            Button("Open in Jira", systemImage: "safari") { openURL(url) }
            Button("Copy URL", systemImage: "link") { Clipboard.copy(url.absoluteString) }
        }
        Button("Copy Key", systemImage: "doc.on.doc") { Clipboard.copy(key) }
    }

    /// Change Status… and Change Assignee…, each opening its picker in a sheet.
    @ViewBuilder
    private func editActions(for issue: IssueSummary) -> some View {
        Button("Change Status…", systemImage: "arrow.triangle.swap") { editing = .status(issue) }
        Button("Change Assignee…", systemImage: "person") { editing = .assignee(issue) }
    }

    private func issue(for ids: Set<IssueSummary.ID>) -> IssueSummary? {
        guard let id = ids.first else { return nil }
        return currentIssues.first { $0.id == id }
    }
}

extension IssueListView where FilterAccessory == EmptyView {
    init(issues: [IssueSummary], onOpen: @escaping (String) -> Void, statusFilterKey: String) {
        self.init(issues: issues, onOpen: onOpen, statusFilterKey: statusFilterKey) { EmptyView() }
    }
}

/// A change started from the list's context menu.
private enum ListEdit: Identifiable {
    case status(IssueSummary)
    case assignee(IssueSummary)

    var issue: IssueSummary {
        switch self {
        case .status(let issue), .assignee(let issue): issue
        }
    }

    var id: String {
        switch self {
        case .status(let issue): "status-\(issue.key)"
        case .assignee(let issue): "assignee-\(issue.key)"
        }
    }
}

/// The issue page's status or assignee picker, in a sheet, since a context
/// menu can't load the choices itself.
private struct ListEditSheet: View {
    let edit: ListEdit
    @Binding var isPresented: Bool
    let onChanged: (IssueSummary) -> Void

    var body: some View {
        let issue = edit.issue
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(.headline)
                Text("\(issue.key) · \(issue.fields.summary)")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)
            Divider()
            switch edit {
            case .status:
                TransitionPicker(issueKey: issue.key, currentStatus: issue.fields.status.name, isPresented: $isPresented) { status in
                    onChanged(issue.with(status: status))
                }
            case .assignee:
                PersonPicker(issueKey: issue.key, role: .assignee, current: issue.fields.assignee, isPresented: $isPresented) { user in
                    onChanged(issue.with(assignee: user))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 320)
    }

    private var title: String {
        switch edit {
        case .status: "Change Status"
        case .assignee: "Change Assignee"
        }
    }
}

private extension IssueSummary {
    func with(status: JiraIssue.Status) -> IssueSummary {
        IssueSummary(id: id, key: key, fields: Fields(
            summary: fields.summary, status: status, issueType: fields.issueType,
            priority: fields.priority, assignee: fields.assignee, updated: .now
        ))
    }

    func with(assignee: JiraUser?) -> IssueSummary {
        IssueSummary(id: id, key: key, fields: Fields(
            summary: fields.summary, status: fields.status, issueType: fields.issueType,
            priority: fields.priority, assignee: assignee, updated: .now
        ))
    }
}

/// One issue in two lines: type and summary, then key, status, assignee
/// and when it last changed.
private struct CompactIssueRow: View {
    let issue: IssueSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            IssueTypeBadge(name: issue.fields.issueType.name, iconOnly: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.fields.summary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(issue.key)
                        .scaledFont(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                    StatusBadge(status: issue.fields.status)
                    Spacer(minLength: 4)
                    if let assignee = issue.fields.assignee {
                        AvatarView(user: assignee, size: 18)
                            .accessibilityLabel(assignee.displayName)
                    }
                    Text(issue.fields.updated, format: .relative(presentation: .named))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private extension IssueSummary {
    func matchesLocalFilter(_ needle: String) -> Bool {
        if key.localizedCaseInsensitiveContains(needle) { return true }
        if fields.summary.localizedCaseInsensitiveContains(needle) { return true }
        if fields.status.name.localizedCaseInsensitiveContains(needle) { return true }
        if fields.issueType.name.localizedCaseInsensitiveContains(needle) { return true }
        if let assignee = fields.assignee?.displayName, assignee.localizedCaseInsensitiveContains(needle) { return true }
        return false
    }
}

/// Footer under an `IssueListView`: count, load-more, spinner, error.
struct IssueListFooter: View {
    let query: IssueQuery
    let onLoadMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if query.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Text(query.issues.count == 1 ? "1 issue" : "\(query.issues.count) issues")
                    .foregroundStyle(.secondary)
                if query.hasMore {
                    Button("Load More", action: onLoadMore)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .scaledFont(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
