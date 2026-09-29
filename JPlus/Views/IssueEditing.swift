import SwiftUI

// Edits made from the issue detail. Each one saves straight to Jira, then
// calls `onChanged` so the page reloads the issue.

// MARK: - Shared pieces

/// A field value that shows a pencil on hover and opens an editor in a popover.
struct EditableFieldButton<Label: View, Editor: View>: View {
    let help: String
    @Binding var isEditing: Bool
    let label: Label
    let editor: () -> Editor

    @State private var isHovered = false

    init(help: String, isEditing: Binding<Bool>, @ViewBuilder label: () -> Label, @ViewBuilder editor: @escaping () -> Editor) {
        self.help = help
        _isEditing = isEditing
        self.label = label()
        self.editor = editor
    }

    var body: some View {
        Button { isEditing = true } label: {
            HStack(alignment: .top, spacing: 6) {
                label
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .opacity(isHovered || isEditing ? 1 : 0)
            }
            .padding(4)
            .background(isHovered || isEditing ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The padding is only for the hover highlight; keep the text in line with the other fields.
        .padding(-4)
        .onHover { isHovered = $0 }
        .help(help)
        .popover(isPresented: $isEditing, arrowEdge: .leading) { editor() }
    }
}

/// A clickable row in a picker popover, highlighted on hover.
private struct PickerRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct ErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Descriptions and comments are written in Jira wiki markup.
private struct WikiMarkupHint: View {
    var body: some View {
        Text("*bold*  _italic_  h2. Heading  * bullet  # numbered  [text|url]  {code}…{code}")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Jira wiki markup")
    }
}

// MARK: - Summary

/// The issue title, with a pencil to rename it in place.
/// Return saves, Esc cancels.
struct EditableSummary: View {
    let issue: JiraIssue
    let onChanged: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var trimmedDraft: String {
        draft.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Summary", text: $draft, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2))
                    .focused($isFocused)
                    .disabled(isSaving)
                    .onSubmit { Task { await save() } }
                    .onExitCommand { cancel() }
                HStack(spacing: 8) {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedDraft.isEmpty || isSaving)
                    Button("Cancel") { cancel() }
                        .disabled(isSaving)
                    if isSaving { ProgressView().controlSize(.small) }
                    if let error { ErrorLabel(message: error) }
                }
                .controlSize(.small)
            }
            // Keeps the text where it was when not editing.
            .padding(.horizontal, -6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(issue.fields.summary)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Button { start() } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0)
                .help("Edit title")
            }
            .onHover { isHovered = $0 }
        }
    }

    private func start() {
        draft = issue.fields.summary
        error = nil
        isEditing = true
        isFocused = true
    }

    private func cancel() {
        isEditing = false
        error = nil
    }

    private func save() async {
        let summary = trimmedDraft
        guard !summary.isEmpty, !isSaving, let client = session.client else { return }
        guard summary != issue.fields.summary else { return cancel() }
        isSaving = true
        error = nil
        do {
            try await client.setSummary(summary, onIssue: issue.key)
            await onChanged()
            isEditing = false
        } catch {
            self.error = "Couldn't rename: \(error.localizedDescription)"
            isFocused = true
        }
        isSaving = false
    }
}

// MARK: - Status

/// The status badge; click to move the issue along its workflow.
struct IssueStatusButton: View {
    let issue: JiraIssue
    let onChanged: () async -> Void

    @State private var isPicking = false
    @State private var isHovered = false

    var body: some View {
        Button { isPicking = true } label: {
            HStack(spacing: 4) {
                StatusBadge(status: issue.fields.status)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(3)
            .background(isHovered || isPicking ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-3)
        .onHover { isHovered = $0 }
        .help("Change status")
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            TransitionPicker(issue: issue, isPresented: $isPicking, onChanged: onChanged)
        }
    }
}

/// The statuses the workflow allows next. Picking one moves the issue at once.
private struct TransitionPicker: View {
    let issue: JiraIssue
    @Binding var isPresented: Bool
    let onChanged: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var transitions: [JiraTransition]?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var savingID: String?

    /// Leaves out moves to the status the issue is already in.
    private var choices: [JiraTransition] {
        (transitions ?? []).filter { $0.to.name != issue.fields.status.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transitions != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if choices.isEmpty {
                            Text("No other statuses available").foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(choices) { row($0) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            } else if let loadError {
                ErrorLabel(message: loadError).padding(12)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading statuses…").foregroundStyle(.secondary)
                }
                .padding(12)
            }
            if let saveError {
                Divider()
                ErrorLabel(message: saveError).padding(10)
            }
        }
        .frame(width: 260, alignment: .leading)
        .task { await load() }
    }

    private func row(_ transition: JiraTransition) -> some View {
        PickerRow {
            Task { await move(transition) }
        } content: {
            StatusBadge(status: transition.to)
            // Workflows sometimes name a move differently from where it leads.
            if transition.name.caseInsensitiveCompare(transition.to.name) != .orderedSame {
                Text(transition.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if savingID == transition.id {
                ProgressView().controlSize(.mini)
            }
        }
        .disabled(savingID != nil)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            transitions = try await client.transitions(issueKey: issue.key)
        } catch {
            loadError = "Couldn't load statuses: \(error.localizedDescription)"
        }
    }

    private func move(_ transition: JiraTransition) async {
        guard let client = session.client, savingID == nil else { return }
        savingID = transition.id
        saveError = nil
        do {
            try await client.transition(issueKey: issue.key, transitionID: transition.id)
            await onChanged()
            isPresented = false
        } catch {
            saveError = "Couldn't move to \(transition.to.name): \(error.localizedDescription). Some moves need fields only Jira's web page asks for."
        }
        savingID = nil
    }
}

// MARK: - Assignee and reporter

enum IssuePersonRole {
    case assignee, reporter

    var title: String {
        switch self {
        case .assignee: "assignee"
        case .reporter: "reporter"
        }
    }
}

/// The assignee or reporter; click to pick someone else.
struct IssuePersonField: View {
    let issue: JiraIssue
    let role: IssuePersonRole
    let onChanged: () async -> Void

    @State private var isEditing = false

    private var user: JiraUser? {
        role == .assignee ? issue.fields.assignee : issue.fields.reporter
    }

    var body: some View {
        EditableFieldButton(help: "Change \(role.title)", isEditing: $isEditing) {
            PersonCell(user: user, avatarSize: 20)
        } editor: {
            PersonPicker(issue: issue, role: role, current: user, isPresented: $isEditing, onChanged: onChanged)
        }
    }
}

/// Search box and matching people. Return picks the first match.
private struct PersonPicker: View {
    let issue: JiraIssue
    let role: IssuePersonRole
    let current: JiraUser?
    @Binding var isPresented: Bool
    let onChanged: () async -> Void

    private enum Choice: Hashable {
        case user(String)
        case unassigned
    }

    @Environment(SessionStore.self) private var session
    @State private var query = ""
    @State private var results: [JiraUser]?
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var saving: Choice?
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// With no search typed, you come first so assigning yourself is one click.
    private var people: [JiraUser] {
        let found = results ?? []
        guard trimmedQuery.isEmpty, let me = session.currentUser else { return found }
        return [me] + found.filter { $0.accountId != me.accountId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search people", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = people.first { Task { await choose(.user(first.accountId)) } }
                }
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if role == .assignee, trimmedQuery.isEmpty, current != nil {
                        PickerRow {
                            Task { await choose(.unassigned) }
                        } content: {
                            AvatarView(url: nil, initials: nil, size: 22)
                            Text("Unassigned")
                            Spacer(minLength: 4)
                            if saving == .unassigned { ProgressView().controlSize(.mini) }
                        }
                    }
                    ForEach(people) { row($0) }
                    if results == nil, searchError == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                        .padding(8)
                    } else if results?.isEmpty == true, !trimmedQuery.isEmpty {
                        Text("No one matches “\(trimmedQuery)”")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    if let searchError { ErrorLabel(message: searchError).padding(8) }
                }
                .padding(6)
            }
            .frame(height: 300)
            .disabled(saving != nil)
            if let saveError {
                Divider()
                ErrorLabel(message: saveError).padding(10)
            }
        }
        .frame(width: 300)
        .onAppear { isSearchFocused = true }
        .task(id: trimmedQuery) { await search() }
    }

    private func row(_ person: JiraUser) -> some View {
        PickerRow {
            Task { await choose(.user(person.accountId)) }
        } content: {
            AvatarView(user: person, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.accountId == session.currentUser?.accountId ? "\(person.displayName) (me)" : person.displayName)
                    .lineLimit(1)
                if let email = person.emailAddress {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if saving == .user(person.accountId) {
                ProgressView().controlSize(.mini)
            } else if person.accountId == current?.accountId {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }

    private func search() async {
        guard let client = session.client else { return }
        let text = trimmedQuery
        // Waits for a pause in typing; a newer query cancels this one.
        if !text.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        do {
            let found = switch role {
            // Only people with the Assignable permission can take the issue.
            case .assignee: try await client.assignableUsers(issueKey: issue.key, query: text)
            case .reporter: try await client.users(matching: text)
            }
            if Task.isCancelled { return }
            results = found
            searchError = nil
        } catch {
            if Task.isCancelled { return }
            results = []
            searchError = "Couldn't search: \(error.localizedDescription)"
        }
    }

    private func choose(_ choice: Choice) async {
        guard let client = session.client, saving == nil else { return }
        let accountID: String? = if case .user(let id) = choice { id } else { nil }
        guard accountID != current?.accountId else {
            isPresented = false
            return
        }
        saving = choice
        saveError = nil
        do {
            switch role {
            case .assignee:
                try await client.setAssignee(accountID: accountID, onIssue: issue.key)
            case .reporter:
                guard let accountID else { break }
                try await client.setReporter(accountID: accountID, onIssue: issue.key)
            }
            await onChanged()
            isPresented = false
        } catch {
            saveError = "Couldn't change the \(role.title): \(error.localizedDescription)"
        }
        saving = nil
    }
}

// MARK: - Description

/// The description, with Edit to rewrite it as wiki markup.
struct DescriptionSection: View {
    let issue: JiraIssue
    let onChanged: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var draft = ""
    /// The markup as loaded, to skip saving when nothing changed.
    @State private var original = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Description").font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if !isEditing {
                    Button("Edit", systemImage: "pencil") { Task { await start() } }
                        .buttonStyle(.borderless)
                        .help("Edit the description")
                }
            }
            if isEditing {
                editor
            } else {
                if let description = issue.fields.description, !description.children.isEmpty {
                    ADFView(node: description)
                } else {
                    Text("No description").foregroundStyle(.secondary)
                }
                if let error { ErrorLabel(message: error) }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .disabled(isSaving)
                .frame(minHeight: 200, maxHeight: 520)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            HStack(spacing: 8) {
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help("Save (⌘↩)")
                Button("Cancel") { isEditing = false }
                    .keyboardShortcut(isFocused ? .cancelAction : nil)
                if isSaving { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                WikiMarkupHint()
            }
            .controlSize(.small)
            .disabled(isSaving)
            if let error { ErrorLabel(message: error) }
        }
    }

    /// Fetches the markup fresh, so the edit starts from what's in Jira now.
    private func start() async {
        guard let client = session.client else { return }
        isLoading = true
        error = nil
        do {
            original = try await client.descriptionWikiMarkup(issueKey: issue.key)
            draft = original
            isEditing = true
            isFocused = true
        } catch {
            self.error = "Couldn't load the description: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func save() async {
        guard let client = session.client, !isSaving else { return }
        guard draft != original else {
            isEditing = false
            return
        }
        isSaving = true
        error = nil
        do {
            try await client.setDescription(wikiMarkup: draft, onIssue: issue.key)
            await onChanged()
            isEditing = false
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - Comments

/// A box under the comments for adding one. ⌘↩ posts.
struct CommentComposer: View {
    let issue: JiraIssue
    let onChanged: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var draft = ""
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    private var isExpanded: Bool { isFocused || !draft.isEmpty }
    private var canPost: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: session.currentUser, size: 28)
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .disabled(isPosting)
                    if draft.isEmpty {
                        Text("Add a comment…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: isExpanded ? 110 : 22)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))

                if isExpanded {
                    HStack(spacing: 8) {
                        Button("Comment") { Task { await post() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canPost)
                            .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                            .help("Post comment (⌘↩)")
                        Button("Cancel") {
                            draft = ""
                            error = nil
                            isFocused = false
                        }
                        .disabled(isPosting)
                        if isPosting { ProgressView().controlSize(.small) }
                        Spacer(minLength: 8)
                        WikiMarkupHint()
                    }
                    .controlSize(.small)
                }
                if let error { ErrorLabel(message: error) }
            }
        }
        .animation(.snappy(duration: 0.15), value: isExpanded)
    }

    private func post() async {
        guard canPost, let client = session.client else { return }
        isPosting = true
        error = nil
        do {
            try await client.addComment(wikiMarkup: draft, to: issue.key)
            draft = ""
            isFocused = false
            await onChanged()
        } catch {
            self.error = "Couldn't post: \(error.localizedDescription)"
        }
        isPosting = false
    }
}
