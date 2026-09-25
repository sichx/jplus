import SwiftUI

/// Main window once signed in: sidebar with account, search, versions and
/// recent issues; detail column shows the selection inside a navigation stack.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    let user: JiraUser

    enum SidebarItem: Hashable {
        case account
        case search
        case versions
        case newTicket
        case issue(String)
    }

    @State private var selection: SidebarItem? = .search
    @State private var path = NavigationPath()
    @State private var issueKeyInput = ""
    @State private var issueKeyError: String?
    @FocusState private var issueFieldFocused: Bool

    @AppStorage("recentIssueKeys") private var recentKeysRaw = ""

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
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: String.self) { key in
                        IssueDetailView(key: key)
                    }
                    .navigationDestination(for: VersionRoute.self) { route in
                        VersionDetailView(route: route, onOpenIssue: pushIssue)
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Go to Issue", systemImage: "number") {
                    issueFieldFocused = true
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Go to Issue (⌘L)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    session.signOut()
                }
            }
        }
        .onChange(of: selection) { path = NavigationPath() }
        .onReceive(NotificationCenter.default.publisher(for: .jplusNewTicket)) { _ in
            selection = .newTicket
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Issue key", text: $issueKeyInput, prompt: Text("VPE-5555"))
                    .textFieldStyle(.roundedBorder)
                    .focused($issueFieldFocused)
                    .onSubmit(openIssueFromInput)
                    .onChange(of: issueKeyInput) { issueKeyError = nil }
                if let issueKeyError {
                    Text(issueKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            List(selection: $selection) {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Versions", systemImage: "shippingbox")
                    .tag(SidebarItem.versions)
                Label("New Ticket", systemImage: "plus.square")
                    .tag(SidebarItem.newTicket)
                Label("Account", systemImage: "person.crop.circle")
                    .tag(SidebarItem.account)

                if !recentKeys.isEmpty {
                    Section("Recent Issues") {
                        ForEach(recentKeys, id: \.self) { key in
                            Label(key, systemImage: "ticket")
                                .tag(SidebarItem.issue(key))
                                .contextMenu {
                                    Button("Remove from Recents") { removeRecent(key) }
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .account:
            AccountView(user: user)
        case .search:
            SearchView(onOpenIssue: pushIssue)
        case .versions:
            VersionsView(suggestedProjectKey: recentProjectKey) { route in
                path.append(route)
            }
        case .newTicket:
            NewTicketView(suggestedProjectKey: recentProjectKey, onCreated: pushIssue)
        case .issue(let key):
            IssueDetailView(key: key)
                .id(key)
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left",
                                   description: Text("Enter an issue key or pick something in the sidebar."))
        }
    }

    // MARK: - Actions

    private func openIssueFromInput() {
        guard let key = IssueKey.parse(issueKeyInput) else {
            issueKeyError = issueKeyInput.isEmpty ? nil : "Enter a key like VPE-5555."
            return
        }
        remember(key)
        selection = .issue(key)
        issueKeyInput = ""
        issueFieldFocused = false
    }

    /// Opens an issue on top of the current view (search results, version).
    private func pushIssue(_ key: String) {
        remember(key)
        path.append(key)
    }

    private func remember(_ key: String) {
        var keys = recentKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        recentKeysRaw = keys.prefix(20).joined(separator: ",")
    }

    private func removeRecent(_ key: String) {
        recentKeysRaw = recentKeys.filter { $0 != key }.joined(separator: ",")
        if selection == .issue(key) { selection = .search }
    }
}

extension Notification.Name {
    /// Posted by the File > New Ticket menu command.
    static let jplusNewTicket = Notification.Name("co.interactivelabs.jplus.newTicket")
}
