import SwiftUI

/// Sidebar "Search": plain words, typo-tolerant, Google-style results.
/// JQL stays available as Advanced search.
struct SearchScreen: View {
    @Binding var query: String
    let submitID: Int
    let index: SearchIndex
    let preferredProject: String?
    let onOpenIssue: (String) -> Void

    @AppStorage("searchMode") private var mode = "simple"

    var body: some View {
        if mode == "jql" {
            JQLSearchView(onOpenIssue: onOpenIssue, onSimpleSearch: { mode = "simple" })
        } else {
            FuzzySearchView(
                query: $query,
                submitID: submitID,
                index: index,
                preferredProject: preferredProject,
                onOpenIssue: onOpenIssue,
                onAdvanced: { mode = "jql" }
            )
        }
    }
}

struct FuzzySearchView: View {
    @Binding var query: String
    let submitID: Int
    let index: SearchIndex
    let preferredProject: String?
    let onOpenIssue: (String) -> Void
    let onAdvanced: () -> Void

    @Environment(SessionStore.self) private var session
    @State private var model = FuzzySearchModel()
    @State private var projects: [JiraProject] = []
    @AppStorage("searchProjectKey") private var projectKey = ""
    @AppStorage("searchOpenOnly") private var openOnly = false
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filters: SearchFilters {
        SearchFilters(projectKey: projectKey.isEmpty ? nil : projectKey, openOnly: openOnly)
    }

    /// Re-run when any input changes, including the index finishing a build.
    private struct Trigger: Hashable {
        let query: String
        let filters: SearchFilters
        let submitID: Int
        let indexRevision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if trimmedQuery.isEmpty {
                home
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .task {
            fieldFocused = true
            guard let client = session.client, let accountID = session.currentAccountID else { return }
            async let loadProjects: Void = { projects = (try? await client.projects()) ?? [] }()
            async let prepareIndex: Void = index.prepare(client: client, accountID: accountID)
            _ = await (loadProjects, prepareIndex)
        }
        .task(id: Trigger(query: trimmedQuery, filters: filters, submitID: submitID, indexRevision: index.revision)) {
            guard !trimmedQuery.isEmpty else { model.clear(); return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let client = session.client else { return }
            await model.search(trimmedQuery, filters: filters, index: index, preferredProject: preferredProject, client: client)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Jira", text: $query, prompt: Text("Search issues in plain words. Typos are fine."))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(fieldFocused ? 0.5 : 0.25)))
            .frame(maxWidth: 680)

            Picker("Project", selection: $projectKey) {
                Text("All projects").tag("")
                if !projects.isEmpty { Divider() }
                ForEach(projects) { project in
                    Text("\(project.key) · \(project.name)").tag(project.key)
                }
            }
            .labelsHidden()
            .fixedSize()

            Toggle("Open only", isOn: $openOnly)
                .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            Button("Advanced (JQL)", action: onAdvanced)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Empty state

    private var home: some View {
        VStack(spacing: 14) {
            Spacer()
            AppIconView(size: 88)
            Text("Search Jira")
                .font(.title.weight(.semibold))
            Text("Type a few words from a title, description or comment. Misspellings and half-typed words still match, and a key like VPE-5636 goes straight to that issue.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            indexStatus
                .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var indexStatus: some View {
        switch index.status {
        case .building(let done, let total):
            VStack(spacing: 6) {
                if let total, total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                        .frame(width: 260)
                }
                Text("Indexing titles for typo-tolerant search… \(done.formatted())\(total.map { " of \($0.formatted())" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("\(index.count.formatted()) issue titles indexed", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Typo-tolerant index unavailable: \(message)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Results

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    statsLine
                    if let suggestion = model.didYouMean {
                        HStack(spacing: 4) {
                            Text("Did you mean:").foregroundStyle(.red)
                            Button(suggestion) { query = suggestion }
                                .buttonStyle(.link)
                                .font(.body.italic().bold())
                        }
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if model.hits.isEmpty && !model.isSearching && model.searchedQuery == trimmedQuery {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your search – \(trimmedQuery) – did not match any issues.")
                        Text("Try different words, fewer words, or turn off Open only and the project filter.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                ForEach(model.visibleHits) { hit in
                    SearchResultRow(
                        hit: hit,
                        snippet: model.snippet(for: hit),
                        queryTokens: model.queryTokens,
                        projectName: projects.first { $0.key == hit.projectKey }?.name,
                        onOpen: { onOpenIssue(hit.key) }
                    )
                }

                if model.canShowMore {
                    Button("More results") {
                        Task { if let client = session.client { await model.showMore(client: client) } }
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statsLine: some View {
        HStack(spacing: 10) {
            if let elapsed = model.elapsed {
                Text("\(model.hits.count == 1 ? "1 result" : "About \(model.hits.count.formatted()) results") (\(elapsed, format: .number.precision(.fractionLength(2))) seconds)")
            }
            if case .building(let done, _) = index.status {
                Text("· indexing titles (\(done.formatted()) so far)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Result row

private struct SearchResultRow: View {
    let hit: SearchHit
    let snippet: String?
    let queryTokens: [String]
    let projectName: String?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IssueTypeBadge(name: hit.typeName, iconOnly: true)
                    .font(.caption)
                Text(hit.key).font(.caption.monospaced())
                if let projectName {
                    Text("· \(projectName)")
                }
                Text("·")
                StatusBadge(status: hit.status).scaleEffect(0.8, anchor: .leading).frame(height: 14)
                if let assignee = hit.assignee {
                    Text("· \(assignee)")
                }
                Text("· \(hit.updated.formatted(.relative(presentation: .named)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Button(action: onOpen) {
                Text(Highlighter.title(hit.summary, matched: hit.matchedTitleWords))
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .underline(isHovering)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open \(hit.key)")

            if let snippet {
                Text(Highlighter.snippet(snippet, queryTokens: queryTokens))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open \(hit.key)", action: onOpen)
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.key, forType: .string)
            }
        }
    }
}

/// Bolds the words that matched, Google-style.
enum Highlighter {
    static func title(_ text: String, matched: Set<String>) -> AttributedString {
        bold(text) { matched.contains($0) }
    }

    static func snippet(_ text: String, queryTokens: [String]) -> AttributedString {
        bold(text) { word in queryTokens.contains { FuzzyMatcher.quality($0, word) >= 0.6 } }
    }

    private static func bold(_ text: String, where shouldBold: (String) -> Bool) -> AttributedString {
        var result = AttributedString()
        var current = ""
        func flushWord() {
            guard !current.isEmpty else { return }
            var piece = AttributedString(current)
            if let normalized = FuzzyMatcher.words(current).first, shouldBold(normalized) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flushWord()
                result += AttributedString(String(character))
            }
        }
        flushWord()
        return result
    }
}
