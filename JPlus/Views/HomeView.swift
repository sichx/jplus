import SwiftUI

/// Main window once signed in. Linear-style sidebar: workspace menu with
/// search and new-ticket icons on top, then navigation and recent issues;
/// the detail column shows the selection inside a navigation stack.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openSettings) private var openSettings
    let user: JiraUser

    enum SidebarItem: Hashable {
        case myIssues
        case mentions
        case version(VersionRoute)
        case account
        case search
        case versions
        case newTicket
        case issue(String)
    }

    /// Nil at launch until the sidebar's versions load; see `chooseStartPage()`.
    @State private var selection: SidebarItem?
    /// Set once the launch page is picked, or once something else is chosen first.
    @State private var hasStartPage = false
    @State private var path = NavigationPath()

    @AppStorage("recentIssueKeys") private var recentKeysRaw = ""
    /// Project chosen on the Versions screen; its versions nest in the sidebar.
    @AppStorage("versionsProjectKey") private var versionsProjectKey = ""
    @AppStorage("sidebarVersionsExpanded") private var versionsExpanded = true
    @State private var sidebarVersions: [VersionRoute] = []
    /// How many recent issues the sidebar shows; grows with Load More.
    @State private var visibleRecentCount = HomeView.recentPageSize
    @State private var showPalette = false
    @State private var searchIndex = SearchIndex()
    @State private var searchQuery = ""
    @State private var searchSubmitID = 0
    @State private var palette = CommandPaletteModel()

    private static let recentPageSize = 7
    private static let recentHistoryLimit = 50

    private var recentKeys: [String] {
        recentKeysRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Project key of the most recently viewed issue, used as a default elsewhere.
    private var recentProjectKey: String? {
        recentKeys.first?.split(separator: "-").first.map(String.init)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: String.self) { key in
                        IssueDetailView(key: key, onOpenIssue: pushIssue)
                    }
                    .navigationDestination(for: VersionRoute.self) { route in
                        VersionDetailView(route: route, onOpenIssue: pushIssue)
                    }
            }
        }
        .onChange(of: selection) {
            path = NavigationPath()
            if selection != nil { hasStartPage = true }
        }
        .task(id: versionsProjectKey.isEmpty ? recentProjectKey : versionsProjectKey) {
            await loadSidebarVersions()
            chooseStartPage()
        }
        .task {
            // Build or refresh the typo-tolerant search index in the background.
            if let client = session.client, let accountID = session.currentAccountID {
                await searchIndex.prepare(client: client, accountID: accountID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jplusLocalDataCleared)) { _ in
            // The saved index is gone; drop the copy in memory and build a fresh one.
            searchIndex.reset()
            if let client = session.client, let accountID = session.currentAccountID {
                Task { await searchIndex.prepare(client: client, accountID: accountID) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jplusNewTicket)) { _ in
            selection = .newTicket
        }
        .onReceive(NotificationCenter.default.publisher(for: .jplusSearch)) { _ in
            openSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jplusCommandPalette)) { _ in
            showPalette ? closePalette() : openPalette()
        }
        .overlay(alignment: .top) {
            if showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture(perform: closePalette)
                    CommandPaletteView(
                        model: palette,
                        defaultProjectKey: recentProjectKey,
                        onOpen: openFromPalette,
                        onClose: closePalette
                    )
                    .padding(.top, 56)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            List(selection: $selection) {
                DisclosureGroup(isExpanded: $versionsExpanded) {
                    ForEach(sidebarVersions, id: \.version.id) { route in
                        SidebarVersionRow(version: route.version)
                            .tag(SidebarItem.version(route))
                    }
                } label: {
                    Label("Versions", systemImage: "shippingbox")
                        .tag(SidebarItem.versions)
                }
                Label("My Issues", systemImage: "person.crop.square")
                    .tag(SidebarItem.myIssues)
                Label("Mentions", systemImage: "at")
                    .tag(SidebarItem.mentions)

                if !recentKeys.isEmpty {
                    Section("Recent Issues") {
                        ForEach(recentKeys.prefix(visibleRecentCount), id: \.self) { key in
                            Label(key, systemImage: "ticket")
                                .tag(SidebarItem.issue(key))
                                .help(recentTitles[key] ?? key)
                                .contextMenu {
                                    Button("Remove from Recents") { removeRecent(key) }
                                }
                        }
                        recentControls
                    }
                }
            }

            Divider()
            accountFooter
        }
    }

    /// App name on the left, Search and New Ticket icons on the right.
    /// Its own row, so nothing competes with the title bar for space.
    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            JPlusMark()
                .foregroundStyle(.secondary)
                .frame(width: 11, height: 15)
                .accessibilityHidden(true)
            Text("for Atlassian\(Text("TM").font(.system(size: 7, weight: .semibold)).baselineOffset(6))")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                // Shrink a little in a narrow sidebar instead of truncating.
                .minimumScaleFactor(0.75)
                .accessibilityLabel("for Atlassian trademark")
            Spacer(minLength: 6)
            headerIcon("magnifyingglass", help: "Search (⌘F)", isActive: selection == .search, action: openSearch)
            headerIcon("square.and.pencil", help: "New Ticket (⌘N)", isActive: selection == .newTicket, filled: true) {
                selection = .newTicket
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func headerIcon(_ symbol: String, help: String, isActive: Bool, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Color.primary.opacity(isActive ? 0.16 : (filled ? 0.09 : 0)))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : .secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// "voloridgehealth.atlassian.net" -> "voloridgehealth"; other hosts as-is.
    private var siteLabel: String? {
        guard let host = session.client?.credentials.siteHost else { return nil }
        let suffix = ".atlassian.net"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }

    /// Signed-in user at the bottom of the sidebar; opens account actions.
    private var accountFooter: some View {
        Menu {
            Button("Account", systemImage: "person.crop.circle") { selection = .account }
            Button("Settings…", systemImage: "gearshape") { openSettings() }
            if let client = session.client {
                Button("Open \(client.credentials.siteHost)", systemImage: "safari") {
                    NSWorkspace.shared.open(client.credentials.siteURL)
                }
            }
            Divider()
            Button("Switch Account…", systemImage: "person.2") { session.signOut() }
        } label: {
            HStack(spacing: 10) {
                AvatarView(user: user, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let site = siteLabel {
                        Text(site)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selection == .account ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .help("Signed in as \(user.displayName)")
    }

    /// Load More / View All / Collapse under the recent issues.
    @ViewBuilder
    private var recentControls: some View {
        let total = recentKeys.count
        if total > Self.recentPageSize {
            // Side by side when the sidebar is wide enough, stacked otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { recentButtons(total: total) }
                VStack(alignment: .leading, spacing: 4) { recentButtons(total: total) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .selectionDisabled()
        }
    }

    @ViewBuilder
    private func recentButtons(total: Int) -> some View {
        let shown = min(visibleRecentCount, total)
        if shown < total {
            Button("Load More") {
                visibleRecentCount = min(visibleRecentCount + Self.recentPageSize, total)
            }
            .help("Show \(min(Self.recentPageSize, total - shown)) more")
            .fixedSize()
            Button("View All (\(total))") {
                visibleRecentCount = total
            }
            .fixedSize()
        }
        if shown > Self.recentPageSize {
            Button("Collapse") {
                visibleRecentCount = Self.recentPageSize
            }
            .help("Show only the \(Self.recentPageSize) most recent")
            .fixedSize()
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .myIssues:
            MyIssuesView(onOpenIssue: pushIssue)
        case .mentions:
            MentionsView(user: user, onOpenIssue: pushIssue)
        case .account:
            AccountView(user: user)
        case .search:
            SearchScreen(
                query: $searchQuery,
                submitID: searchSubmitID,
                index: searchIndex,
                preferredProject: recentProjectKey,
                onOpenIssue: pushIssue
            )
        case .versions:
            VersionsView(suggestedProjectKey: recentProjectKey) { route in
                path.append(route)
            }
        case .version(let route):
            VersionDetailView(route: route, onOpenIssue: pushIssue)
                .id(route.version.id)
        case .newTicket:
            NewTicketView(suggestedProjectKey: recentProjectKey, onCreated: pushIssue)
        case .issue(let key):
            IssueDetailView(key: key, onOpenIssue: pushIssue)
                .id(key)
        case nil where !hasStartPage:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left",
                                   description: Text("Pick something in the sidebar, or press ⌘K to jump to an issue."))
        }
    }

    // MARK: - Actions

    /// The five lowest unreleased versions of the chosen project, by name
    /// ("v1.9" before "v1.17").
    private func loadSidebarVersions() async {
        guard let client = session.client else { return }
        let key = versionsProjectKey.isEmpty ? (recentProjectKey ?? "") : versionsProjectKey
        do {
            let projects = try await client.projects()
            guard let project = projects.first(where: { $0.key == key }) ?? projects.first else { return }
            let versions = try await client.versions(projectKey: project.key)
            sidebarVersions = versions
                .filter { !$0.released && !$0.archived }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .prefix(5)
                .map { VersionRoute(version: $0, project: project) }
        } catch {
            // Keep whatever was shown; the Versions screen reports errors.
        }
    }

    /// Opens on the first version under Versions in the sidebar, or My Issues
    /// if there are none or they couldn't load. Runs once, and not at all if
    /// something was picked while the versions loaded.
    private func chooseStartPage() {
        guard !hasStartPage else { return }
        hasStartPage = true
        selection = sidebarVersions.first.map(SidebarItem.version) ?? .myIssues
    }

    private func openSearch() {
        selection = .search
    }

    /// Opens an issue on top of the current view (search results, version).
    private func pushIssue(_ key: String) {
        remember(key)
        // Opened from ⌘K before the start page was picked; picking it now would clear this.
        hasStartPage = true
        path.append(key)
    }

    private func remember(_ key: String?) {
        guard let key else { return }
        var keys = recentKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        recentKeysRaw = keys.prefix(Self.recentHistoryLimit).joined(separator: ",")
    }

    private var recentTitles: [String: String] {
        guard let id = session.currentAccountID else { return [:] }
        return IssueTitleCache.all(in: AccountDefaults.store(for: id))
    }

    private func openPalette() {
        guard let client = session.client else { return }
        showPalette = true
        let keys = recentKeys
        let titles = recentTitles
        let project = recentProjectKey
        Task {
            await palette.prepare(recentKeys: keys, titles: titles, projectKey: project, client: client)
            if let id = session.currentAccountID {
                IssueTitleCache.save(palette.recentTitles(), in: AccountDefaults.store(for: id))
            }
        }
    }

    private func closePalette() {
        showPalette = false
    }

    private func openFromPalette(_ item: PaletteItem) {
        closePalette()
        switch item {
        case .issue(let issue):
            pushIssue(issue.key)
        case .version(let route):
            remember(nil)
            hasStartPage = true
            path.append(route)
        }
    }

    private func removeRecent(_ key: String) {
        recentKeysRaw = recentKeys.filter { $0 != key }.joined(separator: ",")
        if selection == .issue(key) { selection = .myIssues }
    }
}

extension Notification.Name {
    /// Posted by the File > New Ticket menu command.
    static let jplusNewTicket = Notification.Name("co.interactivelabs.jplus.newTicket")
    /// Posted by Go > Search (⌘F).
    static let jplusSearch = Notification.Name("co.interactivelabs.jplus.search")
    /// Posted by Go > Go to Issue or Version (⌘K).
    static let jplusCommandPalette = Notification.Name("co.interactivelabs.jplus.commandPalette")
}

/// A version nested under Versions in the sidebar.
private struct SidebarVersionRow: View {
    let version: JiraVersion

    var body: some View {
        Label(version.name, systemImage: "tag")
            .lineLimit(1)
            .help(helpText)
    }

    private var helpText: String {
        guard let counts = version.issuesStatusForFixVersion, counts.total > 0 else { return version.name }
        return "\(version.name) · \(counts.done) of \(counts.total) done"
    }
}
