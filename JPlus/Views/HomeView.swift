import SwiftUI

/// Main window once signed in. Linear-style sidebar: workspace menu with
/// search and new-ticket icons on top, then navigation and recent issues;
/// the detail column shows the selection inside a navigation stack.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openAppSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(AppUpdater.self) private var updater: AppUpdater?
    #endif
    let user: JiraUser

    enum SidebarItem: Hashable {
        case myIssues
        case mentions
        case priorities
        /// Nested under Daily Priorities.
        case productQuestions
        case version(VersionRoute)
        /// A Jira space (project), listed under Spaces.
        case space(JiraProject)
        case account
        case search
        case versions
        case newTicket
        case issue(String)
    }

    /// A screen opened on top of the sidebar item.
    enum Destination: Hashable {
        case issue(String)
        case version(VersionRoute)
    }

    /// Nil at launch until the sidebar's versions load; see `chooseStartPage()`.
    @State private var selection: SidebarItem?
    /// Set once the launch page is picked, or once something else is chosen first.
    @State private var hasStartPage = false
    @State private var path: [Destination] = []
    /// Stack to show once a restored sidebar item is selected, since selecting clears the stack.
    @State private var pendingPath: [Destination]?
    /// True while the last session's place is looked up at launch.
    @State private var isRestoringPlace = true
    /// Set once the sidebar's versions have loaded or failed to.
    @State private var hasLoadedSidebarVersions = false
    /// JSON of the last `SavedPlace`.
    @AppStorage("lastPlace") private var lastPlaceData = Data()

    @AppStorage("recentIssueKeys") private var recentKeysRaw = ""
    /// Project chosen on the Versions screen; its versions nest in the sidebar.
    @AppStorage("versionsProjectKey") private var versionsProjectKey = ""
    @AppStorage("sidebarVersionsExpanded") private var versionsExpanded = true
    @AppStorage("sidebarPrioritiesExpanded") private var prioritiesExpanded = true
    @State private var sidebarVersions: [VersionRoute] = []
    @State private var isRefreshingVersions = false
    @AppStorage("sidebarSpacesExpanded") private var spacesExpanded = false
    @State private var sidebarSpaces: [JiraProject] = []
    @State private var spacesFilter = ""
    @FocusState private var spacesFilterFocused: Bool
    /// Set from View > Show in Sidebar, which reads the standard defaults, not this account's.
    @AppStorage(SidebarSection.hiddenStorageKey, store: .standard) private var hiddenSectionsRaw = ""
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

    private func shows(_ section: SidebarSection) -> Bool {
        !SidebarSection.hidden(in: hiddenSectionsRaw).contains(section)
    }

    /// Project key of the most recently viewed issue, used as a default elsewhere.
    private var recentProjectKey: String? { recentProjectKeys.first }

    /// Projects of recently opened issues, most recent first.
    private var recentProjectKeys: [String] {
        var seen = Set<String>()
        return recentKeys
            .compactMap { $0.split(separator: "-").first.map(String.init) }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: Destination.self) { destination in
                        switch destination {
                        case .issue(let key):
                            IssueDetailView(key: key, onOpenIssue: pushIssue)
                        case .version(let route):
                            VersionDetailView(route: route, onOpenIssue: pushIssue)
                        }
                    }
            }
        }
        .onChange(of: selection) {
            path = pendingPath ?? []
            pendingPath = nil
            if selection != nil { hasStartPage = true }
        }
        .onChange(of: currentPlace) {
            if let currentPlace, let data = try? JSONEncoder().encode(currentPlace) {
                lastPlaceData = data
            }
        }
        .task(id: versionsProjectKey.isEmpty ? recentProjectKey : versionsProjectKey) {
            await loadSidebarVersions()
            hasLoadedSidebarVersions = true
            chooseStartPage()
        }
        .task {
            await loadSidebarSpaces()
        }
        .task {
            await restoreLastPlace()
            isRestoringPlace = false
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
                        // One lookup per project for each number typed, so keep the list short.
                        projectKeys: Array(recentProjectKeys.prefix(5)),
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
                if shows(.versions) {
                    #if os(macOS)
                    DisclosureGroup(isExpanded: $versionsExpanded) {
                        sidebarVersionRows
                    } label: {
                        versionsRow
                    }
                    #else
                    // On iOS a disclosure group's label only expands and collapses,
                    // so Versions could never be opened; its versions sit beneath it.
                    versionsRow
                    sidebarVersionRows
                        .padding(.leading, 20)
                    #endif
                }
                if shows(.myIssues) {
                    Label("My Issues", systemImage: "person.crop.square")
                        .tag(SidebarItem.myIssues)
                }
                if shows(.mentions) {
                    Label("Mentions", systemImage: "at")
                        .tag(SidebarItem.mentions)
                }
                if shows(.priorities), shows(.productQuestions) {
                    #if os(macOS)
                    DisclosureGroup(isExpanded: $prioritiesExpanded) {
                        productQuestionsRow
                    } label: {
                        prioritiesRow
                    }
                    #else
                    prioritiesRow
                    productQuestionsRow
                        .padding(.leading, 20)
                    #endif
                } else if shows(.priorities) {
                    prioritiesRow
                } else if shows(.productQuestions) {
                    productQuestionsRow
                }

                if shows(.spaces), !sidebarSpaces.isEmpty {
                    DisclosureGroup(isExpanded: $spacesExpanded) {
                        spacesFilterField
                        let spaces = filteredSpaces
                        if spaces.isEmpty {
                            Text("No spaces match")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        ForEach(spaces) { project in
                            Label(project.name, systemImage: "square.stack")
                                .lineLimit(1)
                                .help("\(project.name) (\(project.key))")
                                .tag(SidebarItem.space(project))
                        }
                    } label: {
                        // Spaces has no screen of its own, so the whole row expands and collapses.
                        Label("Spaces", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation { spacesExpanded.toggle() }
                            }
                    }
                }

                if shows(.recentIssues), !recentKeys.isEmpty {
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

    /// Spaces whose name or key contains the filter text, ignoring case and accents.
    private var filteredSpaces: [JiraProject] {
        let needle = spacesFilter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sidebarSpaces }
        return sidebarSpaces.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.key.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// Styled like the issue list's "Filter this list" field.
    private var spacesFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // The sidebar draws a field's prompt in its label color, whatever
            // style it's given, so the placeholder is drawn here instead.
            TextField("", text: $spacesFilter)
                .textFieldStyle(.plain)
                .focused($spacesFilterFocused)
                .accessibilityLabel("Filter spaces")
                .background(alignment: .leading) {
                    if spacesFilter.isEmpty {
                        Text("Filter spaces")
                            .foregroundStyle(Color.placeholderText)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                #if os(macOS)
                .onExitCommand { spacesFilter = "" }
                #endif
            if !spacesFilter.isEmpty {
                Button {
                    spacesFilter = ""
                    spacesFilterFocused = true
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
                .strokeBorder(Color.secondary.opacity(spacesFilterFocused ? 0.45 : 0.22))
        )
        .selectionDisabled()
    }

    private var prioritiesRow: some View {
        Label("Daily Priorities", systemImage: "checklist")
            .tag(SidebarItem.priorities)
    }

    private var productQuestionsRow: some View {
        Label("Product Questions", systemImage: "questionmark.bubble")
            .tag(SidebarItem.productQuestions)
    }

    private var versionsRow: some View {
        HStack(spacing: 4) {
            Label("Versions", systemImage: "shippingbox")
            Spacer(minLength: 4)
            refreshVersionsButton
        }
        .tag(SidebarItem.versions)
    }

    private var sidebarVersionRows: some View {
        ForEach(sidebarVersions, id: \.version.id) { route in
            SidebarVersionRow(version: route.version)
                .tag(SidebarItem.version(route))
        }
    }

    /// Reloads the versions nested under Versions, e.g. after one is released.
    private var refreshVersionsButton: some View {
        Button {
            Task {
                isRefreshingVersions = true
                await loadSidebarVersions()
                isRefreshingVersions = false
            }
        } label: {
            if isRefreshingVersions {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .disabled(isRefreshingVersions)
        .help("Refresh versions")
        .accessibilityLabel("Refresh versions")
    }

    /// App name on the left, Search and New Ticket icons on the right.
    /// Its own row, so nothing competes with the title bar for space.
    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            JPlusMark()
                .foregroundStyle(.secondary)
                .frame(width: 11, height: 15)
                .accessibilityHidden(true)
            Text("JPlus")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            #if os(iOS)
            // ⌘K on the Mac; without a keyboard it needs a button.
            headerIcon("arrow.right.circle", help: "Go to Issue or Version", isActive: showPalette, action: openPalette)
            #endif
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
                    openURL(client.credentials.siteURL)
                }
            }
            #if os(macOS)
            Button("Check for Updates…", systemImage: "arrow.down.circle") { updater?.checkForUpdates() }
            #endif
            Divider()
            Button("Switch Account…", systemImage: "person.2") { session.switchAccount() }
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
                #if os(macOS)
                if updater?.availableVersion != nil {
                    // Room for the update button, laid over the menu below.
                    Color.clear.frame(width: 22, height: 22)
                }
                #endif
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
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
        #if os(macOS)
        .overlay(alignment: .trailing) {
            // Over the menu rather than in its label, so it gets its own
            // clicks; spaced like the label's chevron and padding.
            HStack(spacing: 10) {
                updateButton
                Color.clear.frame(width: 10)
            }
            .padding(.trailing, 10)
        }
        #endif
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .help("Signed in as \(user.displayName)")
    }

    #if os(macOS)
    /// Shown once Sparkle has a newer version: installs it and relaunches.
    @ViewBuilder private var updateButton: some View {
        if let version = updater?.availableVersion {
            Button {
                updater?.installUpdate()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Update to JPlus \(version) and relaunch")
            .accessibilityLabel("Update to JPlus \(version)")
        }
    }
    #endif

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
        case .priorities:
            PrioritiesView(onOpenIssue: pushIssue)
        case .productQuestions:
            ProductQuestionsView(onOpenIssue: pushIssue)
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
                path.append(.version(route))
            }
        case .version(let route):
            VersionDetailView(route: route, onOpenIssue: pushIssue)
                .id(route.version.id)
        case .space(let project):
            SpaceIssuesView(project: project, onOpenIssue: pushIssue)
                .id(project.key)
        case .newTicket:
            NewTicketView(suggestedProjectKey: recentProjectKey, onCreated: pushIssue)
        case .issue(let key):
            IssueDetailView(key: key, onOpenIssue: pushIssue)
                .id(key)
        case nil where !hasStartPage:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            ScaledContentUnavailableView("Nothing Selected", systemImage: "sidebar.left",
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
            // A version restored before these loaded is a separate copy, so its row wouldn't show as selected.
            if case .version(let current) = selection,
               let match = sidebarVersions.first(where: { $0.version.id == current.version.id }),
               match != current {
                pendingPath = path
                selection = .version(match)
            }
        } catch {
            // Keep whatever was shown; the Versions screen reports errors.
        }
    }

    /// Every Jira space visible to the user, by name, for the Spaces group.
    private func loadSidebarSpaces() async {
        guard let client = session.client else { return }
        do {
            sidebarSpaces = try await client.projects()
        } catch {
            // Leave Spaces out of the sidebar; nothing else depends on it.
        }
    }

    /// Without a place to restore, opens on the first version under Versions
    /// in the sidebar, or My Issues if there are none or they couldn't load.
    /// Either is skipped while hidden from the sidebar.
    /// Runs once, and not at all if something was picked while loading.
    private func chooseStartPage() {
        guard !hasStartPage, !isRestoringPlace, hasLoadedSidebarVersions else { return }
        hasStartPage = true
        let firstVersion = shows(.versions) ? sidebarVersions.first.map(SidebarItem.version) : nil
        selection = firstVersion ?? (shows(.myIssues) ? .myIssues : nil)
    }

    // MARK: - Last place

    /// What's on screen now, in the form that's saved; nil until the start page is up.
    private var currentPlace: SavedPlace? {
        guard hasStartPage, let selection else { return nil }
        let sidebar: SavedPlace.Screen = switch selection {
        case .myIssues: .myIssues
        case .mentions: .mentions
        case .priorities: .priorities
        case .productQuestions: .productQuestions
        case .account: .account
        case .search: .search
        case .versions: .versions
        case .newTicket: .newTicket
        case .issue(let key): .issue(key)
        case .version(let route): .version(projectKey: route.project.key, versionID: route.version.id)
        case .space(let project): .space(project.key)
        }
        let stack: [SavedPlace.Screen] = path.suffix(SavedPlace.maxStackDepth).map {
            switch $0 {
            case .issue(let key): .issue(key)
            case .version(let route): .version(projectKey: route.project.key, versionID: route.version.id)
            }
        }
        return SavedPlace(sidebar: sidebar, stack: stack)
    }

    /// Reopens what was on screen when the app was last used: the sidebar
    /// item and everything opened on top of it. Versions are looked up again;
    /// one that no longer exists is skipped, and if it was the sidebar item
    /// the usual start page opens instead.
    private func restoreLastPlace() async {
        guard let saved = try? JSONDecoder().decode(SavedPlace.self, from: lastPlaceData) else { return }
        var resolver = VersionResolver(client: session.client)
        guard let sidebar = await sidebarItem(for: saved.sidebar, using: &resolver) else { return }
        var stack: [Destination] = []
        for screen in saved.stack {
            switch screen {
            case .issue(let key):
                stack.append(.issue(key))
            case .version(let projectKey, let versionID):
                if let route = await resolver.route(projectKey: projectKey, versionID: versionID) {
                    stack.append(.version(route))
                }
            default:
                break
            }
        }
        // Something was opened while this loaded; leave it.
        guard !hasStartPage else { return }
        hasStartPage = true
        if sidebar == selection {
            path = stack
        } else {
            pendingPath = stack
            selection = sidebar
        }
    }

    private func sidebarItem(for screen: SavedPlace.Screen, using resolver: inout VersionResolver) async -> SidebarItem? {
        switch screen {
        case .myIssues: return .myIssues
        case .mentions: return .mentions
        case .priorities: return .priorities
        case .productQuestions: return .productQuestions
        case .account: return .account
        case .search: return .search
        case .versions: return .versions
        case .newTicket: return .newTicket
        case .issue(let key): return .issue(key)
        case .version(let projectKey, let versionID):
            // The sidebar's own copy if it has loaded, so its row shows as selected.
            if let route = sidebarVersions.first(where: { $0.version.id == versionID }) {
                return .version(route)
            }
            return await resolver.route(projectKey: projectKey, versionID: versionID).map(SidebarItem.version)
        case .space(let key):
            return await resolver.project(key: key).map(SidebarItem.space)
        }
    }

    private func openSearch() {
        selection = .search
    }

    /// Opens an issue on top of the current view (search results, version).
    private func pushIssue(_ key: String) {
        remember(key)
        // Opened from ⌘K before the start page was picked; picking it now would clear this.
        hasStartPage = true
        path.append(.issue(key))
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
            path.append(.version(route))
        }
    }

    private func removeRecent(_ key: String) {
        recentKeysRaw = recentKeys.filter { $0 != key }.joined(separator: ",")
        if selection == .issue(key) { selection = .myIssues }
    }
}

/// Looks up saved versions by id, fetching each project and its versions once.
private struct VersionResolver {
    let client: JiraClient?
    private var projects: [JiraProject]?
    private var versionsByProject: [String: [JiraVersion]] = [:]

    init(client: JiraClient?) {
        self.client = client
    }

    mutating func project(key: String) async -> JiraProject? {
        guard let client else { return nil }
        if projects == nil { projects = try? await client.projects() }
        return projects?.first { $0.key == key }
    }

    mutating func route(projectKey: String, versionID: String) async -> VersionRoute? {
        guard let client else { return nil }
        do {
            if projects == nil { projects = try await client.projects() }
            guard let project = projects?.first(where: { $0.key == projectKey }) else { return nil }
            if versionsByProject[projectKey] == nil {
                versionsByProject[projectKey] = try await client.versions(projectKey: projectKey)
            }
            guard let version = versionsByProject[projectKey]?.first(where: { $0.id == versionID }) else { return nil }
            return VersionRoute(version: version, project: project)
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    /// Posted by the File > New Ticket menu command.
    static let jplusNewTicket = Notification.Name("com.hannagrove.jplus.mac.newTicket")
    /// Posted by Go > Search (⌘F).
    static let jplusSearch = Notification.Name("com.hannagrove.jplus.mac.search")
    /// Posted by Go > Go to Issue or Version (⌘K).
    static let jplusCommandPalette = Notification.Name("com.hannagrove.jplus.mac.commandPalette")
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
