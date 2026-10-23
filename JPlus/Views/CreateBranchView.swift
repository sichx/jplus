import SwiftUI

/// Creates a remote branch from an issue; the name remains editable before submission.
struct CreateBranchView: View {
    let issue: JiraIssue
    @Environment(GitHubStore.self) private var github
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var prefix: BranchPrefix = .feature
    @State private var name = ""
    @State private var base = ""
    @State private var search = ""
    @State private var repositorySearch = ""
    @State private var repositories: [GitHubRepository] = []
    @State private var selectedRepository: GitHubRepository?
    @State private var branchRepository: GitHubRepository?
    @State private var isLoadingRepositories = false
    @State private var repositoryError: String?
    @State private var repositoryRequestID = UUID()
    @State private var branchRequestID = UUID()
    @State private var branchReloadID = UUID()
    @State private var branches: [GitHubBranch] = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var error: String?
    @State private var createdURL: URL?
    @State private var createdName = ""
    @State private var copiedCheckoutCommand = false

    private var connection: GitHubConnection? {
        github.accountID == session.currentAccountID ? github.connection : nil
    }
    private var fullName: String { prefix.branchName(name) }
    private var validation: String? { BranchNaming.creationValidationMessage(fullName) }
    private var visibleBranches: [GitHubBranch] {
        branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.name == base }
    }
    private var visibleRepositories: [GitHubRepository] {
        repositories.filter { repositorySearch.isEmpty || $0.fullName.localizedCaseInsensitiveContains(repositorySearch) || $0 == selectedRepository }
    }
    private struct BranchLoad: Equatable {
        let repository: GitHubRepository?
        let revision: UUID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let createdURL {
                        success(url: createdURL)
                    } else if let connection {
                        form(connection: connection)
                    } else {
                        Text("Connect GitHub to create a branch in your repository.")
                            .foregroundStyle(.secondary)
                        GitHubConnectionEditor()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Create Branch · \(issue.key)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdURL == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(isCreating)
                }
                if connection != nil && createdURL == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create", action: create)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(isLoadingRepositories || isLoading || isCreating || selectedRepository == nil || branchRepository != selectedRepository || base.isEmpty || name.isEmpty || validation != nil || !branches.contains(where: { $0.name == base }))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
        .interactiveDismissDisabled(isCreating)
        .task {
            name = BranchNaming.name(issueKey: issue.key, summary: issue.fields.summary)
            prefix = issue.fields.issueType.name.caseInsensitiveCompare("Bug") == .orderedSame ? .bugfix : .feature
        }
        .task(id: connection) { await loadRepositories() }
        .task(id: BranchLoad(repository: selectedRepository, revision: branchReloadID)) { await loadBranches() }
        .onChange(of: session.currentAccountID) { dismiss() }
    }

    private func form(connection: GitHubConnection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Repository") {
                Text(connection.organization.host).scaledFont(.caption).foregroundStyle(.secondary)
                if isLoadingRepositories {
                    ProgressView("Loading repositories…").controlSize(.small)
                } else if !repositories.isEmpty {
                    TextField("Search repositories", text: $repositorySearch).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Picker("Repository", selection: Binding(get: { selectedRepository }, set: { selectRepository($0) })) {
                        Text("Select a repository…").tag(nil as GitHubRepository?)
                        ForEach(visibleRepositories, id: \.self) { repository in
                            Text(repository.fullName).tag(Optional(repository))
                        }
                    }
                    .labelsHidden()
                } else {
                    Text("No available repositories. Check the token's repository access.").foregroundStyle(.secondary)
                }
                if let repositoryError {
                    Text(repositoryError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh repositories") { Task { await loadRepositories() } }
                    .disabled(isLoadingRepositories || isCreating)
            }
            field("Branch prefix") {
                Picker("Branch prefix", selection: $prefix) {
                    ForEach(BranchPrefix.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if prefix == .other {
                    Text("No prefix is added. Enter a custom prefix in Name if needed, such as docs/ or test/.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            field("Base branch") {
                if selectedRepository == nil {
                    Text("Choose a repository first.").foregroundStyle(.secondary)
                } else if isLoading {
                    ProgressView("Loading branches…").controlSize(.small)
                } else if !branches.isEmpty {
                    TextField("Search branches", text: $search).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Picker("Base branch", selection: $base) {
                        Text("Select a branch…").tag("")
                        ForEach(visibleBranches) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                } else {
                    Text("No branches loaded.").foregroundStyle(.secondary)
                }
                Button("Refresh branches") { branchReloadID = UUID() }
                    .disabled(selectedRepository == nil || isLoadingRepositories || isLoading || isCreating)
            }
            field("Name") {
                TextField("Branch name", text: $name).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !name.contains(issue.key) {
                    Text("Keep \(issue.key) in the name to identify the issue.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            field("Branch preview") {
                Text(fullName).scaledFont(.callout.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(fullName.count)/\(BranchNaming.maximumLength) characters")
                    .scaledFont(.caption)
                    .foregroundStyle(fullName.count > BranchNaming.maximumLength ? Color.red : Color.secondary)
                if let validation, !name.isEmpty {
                    Text(validation).scaledFont(.caption).foregroundStyle(.red)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if isCreating { ProgressView("Creating branch…") }
        }
        .scaledFont(.callout)
        .disabled(isCreating)
    }

    private func success(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Branch created", systemImage: "checkmark.circle.fill")
                .scaledFont(.title3).foregroundStyle(.green)
            Text(createdName).scaledFont(.callout.monospaced())
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            field("Checkout command") {
                Text(BranchNaming.checkoutCommand(createdName))
                    .scaledFont(.callout.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copiedCheckoutCommand ? "Copied" : "Copy Checkout Command",
                       systemImage: copiedCheckoutCommand ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(BranchNaming.checkoutCommand(createdName))
                    copiedCheckoutCommand = true
                }
                Link("Open in GitHub", destination: url)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Save the user's choice immediately, even if they cancel without creating a branch.
    private func selectRepository(_ repository: GitHubRepository?) {
        selectedRepository = repository
        branches = []
        branchRepository = nil
        base = ""
        search = ""
        error = nil
        branchRequestID = UUID()
        branchReloadID = UUID()
        if let repository, let connection, let id = session.currentAccountID,
           connection.organization.contains(repository), repositories.contains(repository) {
            github.rememberRepository(repository, accountID: id)
        }
    }

    private func loadRepositories() async {
        guard let connection, let id = session.currentAccountID else { return }
        let requestID = UUID()
        repositoryRequestID = requestID
        isLoadingRepositories = true
        repositoryError = nil
        repositorySearch = ""
        repositories = []
        selectRepository(nil)
        defer { if repositoryRequestID == requestID { isLoadingRepositories = false } }
        do {
            let client = GitHubClient(organization: connection.organization, token: connection.token)
            let fetched = try await client.repositories()
            try Task.checkCancellation()
            guard repositoryRequestID == requestID, session.currentAccountID == id, self.connection == connection else { return }
            repositories = fetched
            let preferred = github.preferredRepository(in: connection.organization, available: fetched, accountID: id)
            selectRepository(preferred)
        } catch where error.isCancellation {
            return
        } catch {
            guard repositoryRequestID == requestID, session.currentAccountID == id, self.connection == connection else { return }
            repositoryError = error.localizedDescription
        }
    }

    private func loadBranches() async {
        let requestID = UUID()
        branchRequestID = requestID
        guard let connection, let repository = selectedRepository, let id = session.currentAccountID else {
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        defer { if branchRequestID == requestID { isLoading = false } }
        do {
            let client = GitHubClient(organization: connection.organization, token: connection.token)
            async let info = client.repositoryInfo(repository)
            let fetched = try await client.branches(in: repository)
            let metadata = try await info
            try Task.checkCancellation()
            guard branchRequestID == requestID, session.currentAccountID == id, self.connection == connection,
                  selectedRepository == repository else { return }
            guard !metadata.archived, !metadata.disabled else { throw GitHubError.readOnlyRepository }
            branches = fetched
            branchRepository = repository
            if !fetched.contains(where: { $0.name == base }) {
                base = BranchNaming.preferredBase(branches: fetched.map(\.name), fixVersions: issue.fields.fixVersions.map(\.name),
                    saved: github.savedBase(for: repository, accountID: id), defaultBranch: metadata.defaultBranch) ?? ""
            }
            if fetched.isEmpty { error = "This repository has no branches. Initialize it in GitHub before creating a branch." }
        } catch where error.isCancellation {
            return
        } catch {
            guard branchRequestID == requestID, session.currentAccountID == id, self.connection == connection,
                  selectedRepository == repository else { return }
            branches = []
            branchRepository = nil
            base = ""
            self.error = error.localizedDescription
        }
    }

    private func create() {
        guard !isCreating, !isLoading, !isLoadingRepositories, let connection, let repository = selectedRepository,
              branchRepository == repository, repositories.contains(repository), let id = session.currentAccountID,
              !base.isEmpty, !name.isEmpty, validation == nil, branches.contains(where: { $0.name == base }) else { return }
        let branchName = fullName
        let baseName = base
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let client = GitHubClient(organization: connection.organization, token: connection.token)
                let url = try await client.createBranch(name: branchName, base: baseName, in: repository)
                github.rememberBase(baseName, for: repository, accountID: id)
                guard session.currentAccountID == id else { return }
                createdName = branchName
                createdURL = url
            } catch {
                guard session.currentAccountID == id else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
