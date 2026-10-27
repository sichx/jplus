import SwiftUI

/// One version: header with dates and progress, then its issues.
struct VersionDetailView: View {
    let route: VersionRoute
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()
    @State private var highlights: VersionHighlights?
    @State private var isLoadingHighlights = false
    @State private var highlightsError: String?
    @AppStorage("versionHideCompleted") private var hideCompleted = false
    @AppStorage("versionOnlyAppTeam") private var onlyAppTeam = false
    /// Account ids of the App Team's members, once loaded.
    @State private var appTeamMemberIDs: Set<String>?
    @State private var appTeamError: String?
    /// Height of the header's content, measured so the issues can start right below it.
    @State private var headerContentHeight: CGFloat = 0
    /// Header height set by dragging the divider; nil until dragged.
    @State private var draggedHeaderHeight: CGFloat?
    /// Header height when the current drag began.
    @State private var dragStartHeaderHeight: CGFloat?
    #if os(iOS)
    /// The half of the page on screen on iPhone and iPad, where the header
    /// and issues each get the whole page rather than splitting it.
    @AppStorage("versionPage") private var page = Page.highlights

    private enum Page: String {
        case highlights, issues
    }

    /// "v2.6.0" for a name that's just a number; the name as it is otherwise.
    private var versionLabel: String {
        version.name.first?.isNumber == true ? "v\(version.name)" : version.name
    }
    #endif

    /// Past development, so counted as completed along with Jira's Done
    /// category (Done, Won't Do), though Jira files them under In Progress.
    private static let completedStatusNames = ["Ready for QA", "QA", "Ready for UAT", "UAT"]
    /// The team in Atlassian Teams whose members' issues "Only show App Team" keeps.
    private static let appTeamName = "App Team"
    /// Until the divider is dragged, a header taller than this share of the
    /// page scrolls at that height; a shorter one is shown whole.
    private static let defaultMaxHeaderFraction: CGFloat = 0.5
    private static let minIssuesHeight: CGFloat = 160

    private var version: JiraVersion { route.version }

    /// Also filters what's already loaded, so hidden issues disappear as
    /// soon as a toggle flips rather than when the new query returns.
    private var shownIssues: [IssueSummary] {
        var issues = query.issues
        if hideCompleted {
            issues = issues.filter { !Self.isCompleted($0.fields.status) }
        }
        if onlyAppTeam {
            if let appTeamMemberIDs {
                issues = issues.filter { issue in
                    issue.fields.assignee.map { appTeamMemberIDs.contains($0.accountId) } ?? false
                }
            } else if appTeamError != nil {
                // Without the member list nothing can be shown as the team's.
                issues = []
            }
        }
        return issues
    }

    private static func isCompleted(_ status: JiraIssue.Status) -> Bool {
        status.isDone || completedStatusNames.contains { $0.caseInsensitiveCompare(status.name) == .orderedSame }
    }

    var body: some View {
        content
            .navigationTitle(version.name)
            .navigationSubtitleIfAvailable(route.project.name)
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            async let issues: Void = run()
                            async let notes: Void = loadHighlights()
                            _ = await (issues, notes)
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    if let client = session.client {
                        Button("Open in Jira", systemImage: "safari") {
                            openURL(client.browseURL(projectKey: route.project.key, versionID: version.id))
                        }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Open this release in Jira (⇧⌘O)")
                    }
                }
            }
            .loadTask { await run() }
            .loadTask { await loadHighlights() }
            .onChange(of: hideCompleted) { Task { await run() } }
            .onChange(of: onlyAppTeam) { Task { await run() } }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        // A phone's height split between header and issues leaves too little
        // of either, so a segmented control in the navigation bar shows one at
        // a time. Both stay in place, so switching keeps each one's scroll
        // position and filter.
        ZStack {
            ScrollView { header }
                .shown(page == .highlights)
            issues
                .shown(page == .issues)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $page.animation(.easeInOut(duration: 0.2))) {
                    Text("\(versionLabel) Highlights").tag(Page.highlights)
                    Text("Issues").tag(Page.issues)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        #else
        // Not a VSplitView: it keeps its divider where it first put it, so the
        // issues wouldn't follow the header as highlights load or change length.
        GeometryReader { proxy in
            let headerHeight = headerHeight(in: proxy.size.height)
            VStack(spacing: 0) {
                ScrollView {
                    header
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerContentHeight = $0 }
                }
                .frame(height: headerHeight)
                headerDivider(headerHeight: headerHeight)
                issues
                    .frame(maxHeight: .infinity)
            }
        }
        #endif
    }

    /// As tall as the header's content, so the issues start right below its
    /// last line, but never squeezing the issues or (until dragged) taking
    /// more than half the page.
    private func headerHeight(in available: CGFloat) -> CGFloat {
        let limit = draggedHeaderHeight ?? available * Self.defaultMaxHeaderFraction
        let wanted = min(limit, headerContentHeight)
        return max(0, min(wanted, available - Self.minIssuesHeight))
    }

    /// The line between header and issues. Drag it to show more or less of a
    /// header that is too long to show whole.
    private func headerDivider(headerHeight: CGFloat) -> some View {
        Divider()
            // A strip tall enough to grab, with the line through its middle.
            .frame(height: 7)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.rowResize)
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartHeaderHeight ?? headerHeight
                        dragStartHeaderHeight = start
                        draggedHeaderHeight = max(60, start + drag.translation.height)
                    }
                    .onEnded { _ in dragStartHeaderHeight = nil }
            )
    }

    private var header: some View {
        let description = nonEmpty(version.description) ?? highlights?.description
        return VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            // The name is in the navigation bar's picker, so the state leads the description.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VersionStateBadge(version: version)
                if let description {
                    Text(description).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            #else
            HStack(spacing: 10) {
                Text(version.name).scaledFont(.title2.weight(.semibold))
                VersionStateBadge(version: version)
            }
            if let description {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
            #endif
            // Side by side where they fit, stacked on a narrow iPhone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { versionDates }
                VStack(alignment: .leading, spacing: 4) { versionDates }
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)

            if let counts = version.issuesStatusForFixVersion, counts.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    VersionProgressBar(counts: counts)
                        .frame(height: 8)
                        .frame(maxWidth: 480)
                    HStack(spacing: 14) {
                        legend(.green, "\(counts.done) done")
                        legend(.blue, "\(counts.inProgress) in progress")
                        legend(.secondary.opacity(0.4), "\(counts.toDo + counts.unmapped) to do")
                        Text("\(Int((counts.doneFraction * 100).rounded()))%")
                            .fontWeight(.medium)
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            highlightsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var versionDates: some View {
        if let start = version.startDay {
            Label("Start \(start.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
        }
        if let release = version.releaseDay {
            Label("Release \(release.formatted(date: .abbreviated, time: .omitted))", systemImage: "flag.checkered")
        }
    }

    @ViewBuilder
    private var highlightsSection: some View {
        if let highlights, highlights.hasContent, let content = highlights.content {
            Divider().padding(.vertical, 4)
            Text(nonEmpty(highlights.title) ?? "Version highlights")
                .scaledFont(.headline)
            ADFView(node: content)
                .frame(maxWidth: 820, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    // Ticket links on this site open in the app; anything else goes to the browser.
                    if url.host() == session.client?.credentials.siteURL.host(),
                       let key = IssueKey.parse(url.absoluteString) {
                        onOpenIssue(key)
                        return .handled
                    }
                    return .systemAction
                })
        } else if isLoadingHighlights {
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading version highlights…").foregroundStyle(.secondary)
            }
            .scaledFont(.callout)
        } else if let highlightsError {
            Divider().padding(.vertical, 4)
            Label(highlightsError, systemImage: "exclamationmark.triangle")
                .scaledFont(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Fetches this version's highlights directly, so the detail never
    /// depends on the list having finished loading them.
    private func loadHighlights() async {
        guard let client = session.client else { return }
        isLoadingHighlights = highlights == nil
        highlightsError = nil
        defer { isLoadingHighlights = false }
        do {
            let cloudId = try await session.cloudId()
            let found = try await client.versionHighlights(projectId: route.project.id, cloudId: cloudId, search: version.name)
            highlights = found[version.id]
        } catch where error.isCancellation {
            // Loads again when the page reappears.
        } catch {
            if highlights == nil {
                highlightsError = "Couldn't load version highlights: \(error.localizedDescription)"
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    @ViewBuilder
    private var issues: some View {
        if let message = query.errorMessage {
            ScaledContentUnavailableView {
                Label("Couldn't Load Issues", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if (query.isLoading || !query.hasRun) && query.issues.isEmpty {
            // Not run yet counts as loading: the first query can wait on the site's status list.
            ProgressView("Loading issues…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty && !hideCompleted && !onlyAppTeam {
            ScaledContentUnavailableView("No Issues", systemImage: "shippingbox",
                                         description: Text("Nothing has this fix version yet."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: shownIssues, onOpen: onOpenIssue) {
                    Toggle("Hide completed", isOn: $hideCompleted)
                        .checkboxToggleStyle()
                        .fixedSize()
                        .help("Hide issues from Ready for QA onward: QA, Ready for UAT, UAT, and done statuses such as Done and Won't Do")
                    Toggle("Only show \(Self.appTeamName)", isOn: $onlyAppTeam)
                        .checkboxToggleStyle()
                        .fixedSize()
                        .help("Show only issues assigned to a member of \(Self.appTeamName) in Atlassian Teams")
                    Button("Open in Jira", systemImage: "safari") {
                        Task { if let url = await listURL() { openURL(url) } }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!canLinkToList)
                    .help("Open this list in Jira's issue search, with the same filters")
                    .contextMenu {
                        Button("Copy URL") {
                            Task {
                                guard let url = await listURL() else { return }
                                Clipboard.copy(url.absoluteString)
                            }
                        }
                    }
                }
                #if os(macOS)
                // Blank rather than striped when empty, or the stripes behind the message read as rows.
                .alternatingRowBackgrounds(shownIssues.isEmpty ? .disabled : .automatic)
                #endif
                // An overlay rather than its own branch, so the toggles stay on screen to turn back off.
                .overlay {
                    if onlyAppTeam, let appTeamError {
                        ScaledContentUnavailableView("Couldn't Load \(Self.appTeamName)", systemImage: "exclamationmark.triangle",
                                                     description: Text(appTeamError))
                            .allowsHitTesting(false)
                    } else if hideCompleted || onlyAppTeam, query.hasRun, !query.isLoading, shownIssues.isEmpty {
                        emptyFilteredView.allowsHitTesting(false)
                    }
                }
                if showsFooter {
                    Divider()
                    IssueListFooter(query: query) {
                        Task {
                            if let client = session.client { await query.loadMore(using: client) }
                        }
                    }
                }
            }
        }
    }

    /// On iPhone and iPad only while there's more to load: the count alone
    /// isn't worth a row there.
    private var showsFooter: Bool {
        #if os(iOS)
        query.hasMore
        #else
        true
        #endif
    }

    @ViewBuilder
    private var emptyFilteredView: some View {
        let outsideTeam = "issues assigned outside \(Self.appTeamName)"
        if !onlyAppTeam {
            ScaledContentUnavailableView("No Open Issues", systemImage: "checkmark.circle",
                                         description: Text("Completed issues are hidden."))
        } else if hideCompleted {
            ScaledContentUnavailableView("No Open Issues", systemImage: "checkmark.circle",
                                         description: Text("Completed issues and \(outsideTeam) are hidden."))
        } else {
            ScaledContentUnavailableView("No \(Self.appTeamName) Issues", systemImage: "person.2",
                                         description: Text("Unassigned issues and \(outsideTeam) are hidden."))
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        let hiding = hideCompleted
        let teamOnly = onlyAppTeam
        var assignees: Set<String>?
        if teamOnly {
            do {
                assignees = try await session.teamMemberIDs(teamNamed: Self.appTeamName)
                appTeamError = nil
            } catch where error.isCancellation {
                return
            } catch {
                appTeamError = error.localizedDescription
            }
            appTeamMemberIDs = assignees
        }
        let jql = await jql(hidingCompleted: hiding, assignees: assignees)
        // Toggled again while the team or status list loaded; that newer run takes over.
        guard hiding == hideCompleted, teamOnly == onlyAppTeam else { return }
        await query.run(jql, using: client, keepingResults: true)
    }

    /// False only once it's known a query can't say what the toggles show:
    /// Only show App Team is on and the team couldn't be loaded or has no
    /// members to name as assignees. While they load, the link waits for them.
    private var canLinkToList: Bool {
        !onlyAppTeam || (appTeamError == nil && appTeamMemberIDs?.isEmpty != true)
    }

    /// Jira's issue search on the web, running this list's query as the
    /// toggles stand now rather than as last fetched.
    private func listURL() async -> URL? {
        guard let client = session.client else { return nil }
        var assignees: Set<String>?
        if onlyAppTeam {
            // Already fetched for the list as a rule; a click before then waits here.
            guard let members = try? await session.teamMemberIDs(teamNamed: Self.appTeamName),
                  !members.isEmpty else { return nil }
            assignees = members
        }
        return client.browseURL(jql: await jql(hidingCompleted: hideCompleted, assignees: assignees))
    }

    private func jql(hidingCompleted: Bool, assignees: Set<String>?) async -> String {
        var clauses = ["project = \(route.project.key)", "fixVersion = \(version.id)"]
        // An empty list isn't valid JQL; an empty team's rows are all hidden once loaded anyway.
        if let assignees, !assignees.isEmpty {
            clauses.append("assignee in (\(assignees.sorted().map { "\"\($0)\"" }.joined(separator: ", ")))")
        }
        if hidingCompleted {
            clauses.append("statusCategory != Done")
            // JQL rejects status names the site doesn't have, so name only those
            // it does. The rest are still hidden from the rows that load.
            let onSite = (try? await session.statusNames()) ?? []
            let names = Self.completedStatusNames.filter { onSite.contains($0.lowercased()) }
            if !names.isEmpty {
                clauses.append("status not in (\(names.map { "\"\($0)\"" }.joined(separator: ", ")))")
            }
        }
        return clauses.joined(separator: " AND ") + " ORDER BY status ASC, priority DESC, updated DESC"
    }
}

#if os(iOS)
private extension View {
    /// On screen, or kept in place unseen and out of reach.
    func shown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}
#endif
