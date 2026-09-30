import AppKit
import QuickLook
import SwiftUI

/// Loads and displays one issue by key.
struct IssueDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    let key: String
    /// Opens another issue in the app, such as the parent or a sub-task.
    let onOpenIssue: (String) -> Void

    private enum Phase {
        case loading
        case loaded(JiraIssue)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var extras = IssueExtras()
    @State private var children: IssueSearchPage?
    @State private var previewURL: URL?
    @State private var attachmentError: String?
    @AppStorage("showIssueDetailsPane") private var showDetailsPane = true

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading \(key)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load \(key)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            case .loaded(let issue):
                IssueContentView(issue: issue, extras: extras, children: children, onOpenIssue: onOpenIssue, onChanged: reloadIssue)
            }
        }
        .navigationTitle(key)
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showDetailsPane) {
            Group {
                if case .loaded(let issue) = phase {
                    IssueDetailsPane(issue: issue, onOpenIssue: onOpenIssue, onChanged: reloadIssue)
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .environment(\.adfMedia, mediaContext)
        .quickLookPreview($previewURL)
        .alert("Couldn't Open Attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDetailsPane.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help(showDetailsPane ? "Hide ticket details (⌥⌘0)" : "Show ticket details (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .keyboardShortcut("r", modifiers: .command)
                if let client = session.client {
                    Button("Open in Jira", systemImage: "safari") {
                        openURL(client.browseURL(for: key))
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help("Open this issue in Jira (⇧⌘O)")
                }
            }
        }
        .task { await load() }
    }

    private var subtitle: String {
        if case .loaded(let issue) = phase { return issue.fields.summary }
        return ""
    }

    /// Lets the description, comments and attachment list show and open this issue's files.
    private var mediaContext: ADFMediaContext? {
        guard case .loaded(let issue) = phase, let client = session.client else { return nil }
        return ADFMediaContext(
            client: client,
            attachments: issue.fields.attachments ?? [],
            attachmentIDsByMediaID: extras.attachmentIDsByMediaID,
            preview: { attachment in
                do {
                    previewURL = try await AttachmentStore.shared.file(for: attachment, using: client)
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        )
    }

    private func load() async {
        guard let client = session.client else {
            phase = .failed("Not signed in.")
            return
        }
        phase = .loading
        // Designs and attachment media ids come from the GraphQL gateway, and
        // child issues from a search: fetched alongside the issue, but never
        // holding it up or failing it.
        async let fetchedExtras = loadExtras(using: client)
        async let fetchedChildren = loadChildren(using: client)
        do {
            let issue = try await client.issue(key: key)
            phase = .loaded(issue)
            if let id = session.currentAccountID {
                IssueTitleCache.save([issue.key: issue.fields.summary], in: AccountDefaults.store(for: id))
            }
        } catch JiraError.notFound {
            phase = .failed("No issue with key \(key), or you don't have permission to view it.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
        if let fetched = await fetchedChildren { children = fetched }
        if let fetched = await fetchedExtras { extras = fetched }
    }

    /// Re-reads the issue after an edit, keeping the page on screen.
    private func reloadIssue() async {
        guard let client = session.client, let issue = try? await client.issue(key: key) else { return }
        phase = .loaded(issue)
        if let id = session.currentAccountID {
            IssueTitleCache.save([issue.key: issue.fields.summary], in: AccountDefaults.store(for: id))
        }
    }

    /// Nil if the search fails, so a refresh keeps what's already shown.
    /// Until a search succeeds, the sub-tasks embedded in the issue are listed.
    private func loadChildren(using client: JiraClient) async -> IssueSearchPage? {
        try? await client.childIssues(of: key)
    }

    /// Nil if the gateway fails, so a refresh keeps what's already shown.
    private func loadExtras(using client: JiraClient) async -> IssueExtras? {
        do {
            let cloudId = try await session.cloudId()
            return try await client.issueExtras(key: key, cloudId: cloudId)
        } catch {
            return nil
        }
    }
}

// MARK: - Content

private struct IssueContentView: View {
    let issue: JiraIssue
    let extras: IssueExtras
    /// Search results for the issue's children; nil until loaded.
    let children: IssueSearchPage?
    let onOpenIssue: (String) -> Void
    /// Called after an edit is saved, to reload the issue.
    let onChanged: () async -> Void

    private var fields: JiraIssue.Fields { issue.fields }

    /// The search results once loaded: they include assignees and an epic's
    /// child issues. Until then, the sub-tasks embedded in the issue.
    private var childIssues: [ChildIssue] {
        if let children { return children.issues.map(ChildIssue.init) }
        return (fields.subtasks ?? []).map(ChildIssue.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                DescriptionSection(issue: issue, onChanged: onChanged)
                if !childIssues.isEmpty {
                    Divider()
                    ChildIssuesSection(
                        title: fields.issueType.isEpicLevel ? "Child issues" : "Subtasks",
                        parentKey: issue.key,
                        children: childIssues,
                        showsAssignees: children != nil,
                        isTruncated: children.map { $0.nextPageToken != nil && $0.isLast != true } ?? false,
                        onOpen: onOpenIssue
                    )
                }
                if !extras.designs.isEmpty {
                    Divider()
                    section("Designs (\(extras.designs.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(extras.designs) { design in
                                DesignRow(design: design)
                            }
                        }
                    }
                }
                Divider()
                comments
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let parent = fields.parent {
                    ParentBreadcrumb(parent: parent, onOpen: onOpenIssue)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                IssueTypeBadge(name: fields.issueType.name)
                    .fixedSize()
                Text(issue.key)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize()
                Spacer()
                IssueStatusButton(issue: issue, onChanged: onChanged)
                    .fixedSize()
            }
            EditableSummary(issue: issue, onChanged: onChanged)
        }
    }

    private var comments: some View {
        let list = fields.comment?.comments ?? []
        return section("Comments (\(fields.comment?.total ?? list.count))") {
            VStack(alignment: .leading, spacing: 16) {
                if list.isEmpty {
                    Text("No comments").foregroundStyle(.secondary)
                }
                ForEach(list) { comment in
                    CommentView(comment: comment)
                }
                CommentComposer(issue: issue, onChanged: onChanged)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

// MARK: - Details pane (right-hand column)

/// Ticket fields, Cursor prompt actions and attachments, shown in the right-hand column.
private struct IssueDetailsPane: View {
    let issue: JiraIssue
    let onOpenIssue: (String) -> Void
    /// Called after an edit is saved, to reload the issue.
    let onChanged: () async -> Void

    @State private var copiedPromptToast = false

    private var fields: JiraIssue.Fields { issue.fields }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Details").font(.headline)
                    Spacer()
                    IssueStatusButton(issue: issue, onChanged: onChanged)
                }

                VStack(alignment: .leading, spacing: 14) {
                    field("Assignee") { IssuePersonField(issue: issue, role: .assignee, onChanged: onChanged) }
                    field("Reporter") { IssuePersonField(issue: issue, role: .reporter, onChanged: onChanged) }
                    field("Type") { IssueTypeBadge(name: fields.issueType.name) }
                    // Always shown, so a priority can be set on an issue without one.
                    field("Priority") { IssuePriorityField(issue: issue, onChanged: onChanged) }
                    if let parent = fields.parent {
                        field("Parent") { ParentCard(parent: parent, onOpen: onOpenIssue) }
                    }
                    // Always shown, so a version can be added to an issue without one.
                    field("Fix versions") { FixVersionsField(issue: issue, onChanged: onChanged) }
                    if !fields.components.isEmpty {
                        field("Components") { TagList(items: fields.components.map(\.name)) }
                    }
                    if !fields.labels.isEmpty {
                        field("Labels") { TagList(items: fields.labels) }
                    }
                    field("Created") {
                        Text(fields.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    field("Updated") {
                        Text(fields.updated, format: .relative(presentation: .named))
                            .help(fields.updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)

                if let promptKind = IssueCursorPromptKind.forIssue(issue) {
                    Divider()
                    IssueCursorPromptButton(kind: promptKind) {
                        copyPrompt(kind: promptKind)
                    }
                }

                if let attachments = fields.attachments, !attachments.isEmpty {
                    Divider()
                    AttachmentList(attachments: attachments)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if copiedPromptToast {
                Text("Prompt copied")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: copiedPromptToast)
    }

    private func copyPrompt(kind: IssueCursorPromptKind) {
        let text = IssueCursorPrompts.text(for: issue, kind: kind)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedPromptToast = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedPromptToast = false
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Every file attached to the issue, newest first. Click one to preview it.
private struct AttachmentList: View {
    let attachments: [JiraIssue.Attachment]

    private var newestFirst: [JiraIssue.Attachment] {
        attachments.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments (\(attachments.count))").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(newestFirst) { attachment in
                    AttachmentRow(attachment: attachment)
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

private struct AttachmentRow: View {
    let attachment: JiraIssue.Attachment

    @Environment(\.adfMedia) private var media
    @State private var thumbnail: NSImage?
    @State private var isOpening = false
    @State private var isHovered = false

    var body: some View {
        Button {
            guard let media else { return }
            Task {
                isOpening = true
                await media.preview(attachment)
                isOpening = false
            }
        } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isOpening {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)
            .padding(6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .onHover { isHovered = $0 }
        .help("Preview \(attachment.filename)")
        .task(id: attachment.id) {
            guard attachment.isImage, let media else { return }
            thumbnail = try? await AttachmentStore.shared.thumbnail(for: attachment, using: media.client)
        }
    }

    private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: attachment.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.5))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.quaternary))
    }

    /// "335 kB · Sep 8, 2026"
    private var details: String {
        var parts: [String] = []
        if let size = attachment.size {
            parts.append(Int64(size).formatted(.byteCount(style: .file)))
        }
        if let created = attachment.created {
            parts.append(created.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Fix versions

/// The issue's fix versions. Click to check or uncheck versions in a popover.
private struct FixVersionsField: View {
    let issue: JiraIssue
    let onChanged: () async -> Void

    @State private var isEditing = false
    /// The project's versions, loaded when the popover first opens and kept for reopening.
    @State private var projectVersions: [JiraVersion]?

    var body: some View {
        EditableFieldButton(help: "Change fix versions", isEditing: $isEditing) {
            if issue.fields.fixVersions.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                TagList(items: issue.fields.fixVersions.map(\.name))
            }
        } editor: {
            FixVersionsPicker(issue: issue, projectVersions: $projectVersions, onChanged: onChanged)
        }
    }
}

/// A checkbox per version of the issue's project. Each click is saved at once.
private struct FixVersionsPicker: View {
    let issue: JiraIssue
    @Binding var projectVersions: [JiraVersion]?
    let onChanged: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var checked: Set<String> = []
    /// Versions the issue had when the popover opened. They stay in the top
    /// list while it's open, so unchecking one doesn't move it away.
    @State private var initiallyChecked: Set<String> = []
    @State private var saving: Set<String> = []
    @State private var showsReleased = false
    @State private var loadError: String?
    @State private var saveError: String?

    /// Past this many rows the list scrolls instead of growing the popover.
    private static let maxUnscrolledRows = 12

    /// Unreleased versions, plus any the issue had, lowest first ("v1.9" before "v1.17").
    private var topVersions: [JiraVersion] {
        (projectVersions ?? [])
            .filter { (!$0.released && !$0.archived) || initiallyChecked.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Released versions the issue didn't have, most recently released first.
    /// By date rather than name, since names mix schemes ("App_05_17_2024", "V1.0.1").
    private var releasedVersions: [JiraVersion] {
        (projectVersions ?? [])
            .filter { $0.released && !$0.archived && !initiallyChecked.contains($0.id) }
            .sorted {
                // `yyyy-MM-dd` strings sort by date; undated versions go last.
                let (a, b) = ($0.releaseDate ?? "", $1.releaseDate ?? "")
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedDescending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if projectVersions != nil {
                let rowCount = topVersions.count + (showsReleased ? releasedVersions.count : 0)
                if rowCount > Self.maxUnscrolledRows {
                    ScrollView { list }
                        .frame(height: 360)
                } else {
                    list
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading versions…").foregroundStyle(.secondary)
                }
                .padding(12)
            }

            if let saveError {
                Divider()
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
        .frame(width: 280, alignment: .leading)
        .task { await start() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            if topVersions.isEmpty {
                Text("No unreleased versions").foregroundStyle(.secondary)
            }
            ForEach(topVersions) { row($0) }
            if !releasedVersions.isEmpty {
                // Not a DisclosureGroup: its content is inset, which knocks the dates out of line.
                Button {
                    showsReleased.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsReleased ? 90 : 0))
                            .frame(width: 14)
                        Text("Released (\(releasedVersions.count))")
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                if showsReleased {
                    ForEach(releasedVersions) { row($0) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ version: JiraVersion) -> some View {
        HStack(spacing: 8) {
            Toggle(version.name, isOn: Binding(
                get: { checked.contains(version.id) },
                set: { include in Task { await save(version, included: include) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(saving.contains(version.id))
            Spacer(minLength: 8)
            if saving.contains(version.id) {
                ProgressView().controlSize(.mini)
            } else if let day = version.releaseDay {
                Text(day.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(version.overdue == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(version.overdue == true ? "Overdue: past its release date" : "Release date")
            }
        }
    }

    private func start() async {
        checked = Set(issue.fields.fixVersions.map(\.id))
        initiallyChecked = checked
        guard projectVersions == nil, let client = session.client else { return }
        do {
            projectVersions = try await client.versionsWithoutCounts(projectKey: issue.projectKey)
        } catch {
            loadError = "Couldn't load versions: \(error.localizedDescription)"
        }
    }

    /// Checks or unchecks straight away, then saves; undone if Jira refuses.
    private func save(_ version: JiraVersion, included: Bool) async {
        guard let client = session.client, !saving.contains(version.id) else { return }
        saveError = nil
        saving.insert(version.id)
        if included { checked.insert(version.id) } else { checked.remove(version.id) }
        do {
            try await client.setFixVersion(id: version.id, included: included, onIssue: issue.key)
            saving.remove(version.id)
            await onChanged()
        } catch {
            saving.remove(version.id)
            if included { checked.remove(version.id) } else { checked.insert(version.id) }
            saveError = "Couldn't \(included ? "add" : "remove") \(version.name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Parent and child issues

/// A sub-task or child issue as listed on its parent.
private struct ChildIssue: Identifiable {
    let key: String
    let summary: String
    let status: JiraIssue.Status?
    let typeName: String?
    let assignee: JiraUser?

    var id: String { key }

    init(_ issue: IssueSummary) {
        key = issue.key
        summary = issue.fields.summary
        status = issue.fields.status
        typeName = issue.fields.issueType.name
        assignee = issue.fields.assignee
    }

    init(_ ref: JiraIssue.IssueRef) {
        key = ref.key
        summary = ref.fields?.summary ?? ref.key
        status = ref.fields?.status
        typeName = ref.fields?.issueType?.name
        assignee = nil
    }
}

/// Sub-tasks, or an epic's child issues, with overall progress. Long lists
/// start collapsed; rows open the issue in the app.
private struct ChildIssuesSection: View {
    let title: String
    let parentKey: String
    let children: [ChildIssue]
    /// False while listing the sub-tasks embedded in the issue, which carry no assignee.
    let showsAssignees: Bool
    /// More children exist than one search returns; the rest are linked in Jira.
    let isTruncated: Bool
    let onOpen: (String) -> Void

    @Environment(SessionStore.self) private var session
    @State private var isExpanded = false

    private static let collapsedLimit = 10

    private var visibleChildren: ArraySlice<ChildIssue> {
        isExpanded ? children[...] : children.prefix(Self.collapsedLimit)
    }

    private var counts: JiraVersion.IssueStatusCounts {
        var toDo = 0, inProgress = 0, done = 0
        for child in children {
            switch child.status?.statusCategory?.key {
            case "done": done += 1
            case "indeterminate": inProgress += 1
            default: toDo += 1
            }
        }
        return JiraVersion.IssueStatusCounts(unmapped: 0, toDo: toDo, inProgress: inProgress, done: done)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(title) (\(children.count)\(isTruncated ? "+" : ""))").font(.headline)
                Spacer()
                // A partial list would give a misleading percentage.
                if !isTruncated { progress }
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleChildren.enumerated()), id: \.element.id) { index, child in
                    if index > 0 { Divider() }
                    ChildIssueRow(child: child, showsAssignee: showsAssignees, onOpen: onOpen)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            footer
        }
    }

    private var progress: some View {
        let counts = counts
        return HStack(spacing: 8) {
            VersionProgressBar(counts: counts)
                .frame(width: 120, height: 6)
            Text("\(counts.done) of \(counts.total) done")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help("\(counts.done) done, \(counts.inProgress) in progress, \(counts.toDo) to do")
    }

    @ViewBuilder
    private var footer: some View {
        let hiddenCount = children.count - Self.collapsedLimit
        if hiddenCount > 0 || isTruncated {
            HStack(spacing: 16) {
                if hiddenCount > 0 {
                    Button(isExpanded ? "Show Less" : "Show \(hiddenCount) More") {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                    }
                }
                if isTruncated, let client = session.client {
                    Link("View All in Jira", destination: client.browseURL(jql: JiraClient.childIssuesJQL(of: parentKey)))
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }
}

private struct ChildIssueRow: View {
    let child: ChildIssue
    let showsAssignee: Bool
    let onOpen: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        Button { onOpen(child.key) } label: {
            HStack(spacing: 10) {
                IssueTypeBadge(name: child.typeName ?? "Issue", iconOnly: true)
                    .frame(width: 18)
                Text(child.key)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(child.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsAssignee {
                    AvatarView(user: child.assignee, size: 20)
                        .help(child.assignee?.displayName ?? "Unassigned")
                }
                if let status = child.status {
                    // Fixed column so the badges line up whatever their length.
                    StatusBadge(status: status)
                        .frame(minWidth: 110, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(child.summary)
        .contextMenu { IssueKeyMenu(key: child.key, onOpen: onOpen) }
    }
}

/// The parent at the start of the header: type, key and title. Opens the parent.
private struct ParentBreadcrumb: View {
    let parent: JiraIssue.IssueRef
    let onOpen: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        Button { onOpen(parent.key) } label: {
            HStack(spacing: 5) {
                if let typeName = parent.fields?.issueType?.name {
                    IssueTypeBadge(name: typeName, iconOnly: true)
                }
                Text(parent.key)
                    .monospaced()
                    .fixedSize()
                if let summary = parent.fields?.summary {
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.callout)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keeps the text flush with the title below; the padding is only for the hover highlight.
        .padding(.leading, -6)
        .onHover { isHovered = $0 }
        .help("Open parent \(parent.key)")
        .contextMenu { IssueKeyMenu(key: parent.key, onOpen: onOpen) }
    }
}

/// The parent in the details column: type, key, status and title. Opens the parent.
private struct ParentCard: View {
    let parent: JiraIssue.IssueRef
    let onOpen: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        Button { onOpen(parent.key) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let typeName = parent.fields?.issueType?.name {
                        IssueTypeBadge(name: typeName, iconOnly: true)
                    }
                    Text(parent.key).font(.callout.monospaced())
                    Spacer(minLength: 4)
                    if let status = parent.fields?.status {
                        StatusBadge(status: status)
                    }
                }
                if let summary = parent.fields?.summary {
                    Text(summary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovered ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(parent.key)")
        .contextMenu { IssueKeyMenu(key: parent.key, onOpen: onOpen) }
    }
}

/// Open, Open in Jira, Copy URL, and Copy Key, as in issue lists.
private struct IssueKeyMenu: View {
    let key: String
    let onOpen: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open \(key)") { onOpen(key) }
        if let client = session.client {
            let url = client.browseURL(for: key)
            Button("Open in Jira") { openURL(url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Copy Key") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        }
    }
}

// MARK: - Pieces

private struct IssueCursorPromptButton: View {
    let kind: IssueCursorPromptKind
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Button(action: action) {
                Label(kind.buttonTitle, systemImage: kind.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Copy a prompt for Cursor (paste into chat)")
        }
    }
}

/// A linked design, with buttons to open it in Figma.
private struct DesignRow: View {
    let design: IssueDesign

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.ruler.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 36, height: 36)
                .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(design.name)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(design.providerName).foregroundStyle(.secondary)
                    if design.isReadyForDev {
                        ReadyForDevBadge()
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 12)
            if let inspectURL = design.inspectURL, inspectURL != design.url {
                Button("Dev Mode") { openURL(inspectURL) }
                    .help("Open in \(design.providerName)'s Dev Mode")
            }
            Button("Open in \(design.providerName)") { openURL(design.url) }
                .help(design.url.absoluteString)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Open in \(design.providerName)") { openURL(design.url) }
            if let inspectURL = design.inspectURL, inspectURL != design.url {
                Button("Open in Dev Mode") { openURL(inspectURL) }
            }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(design.url.absoluteString, forType: .string)
            }
        }
    }
}

private struct ReadyForDevBadge: View {
    var body: some View {
        Label("Ready for dev", systemImage: "chevron.left.forwardslash.chevron.right")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.green)
    }
}

private struct CommentView: View {
    let comment: JiraIssue.Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: comment.author, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author?.displayName ?? "Unknown").fontWeight(.medium)
                    Text(comment.created, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(comment.created.formatted(date: .abbreviated, time: .shortened))
                    if comment.updated.timeIntervalSince(comment.created) > 60 {
                        Text("(edited)").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                if let body = comment.body {
                    ADFView(node: body)
                }
            }
        }
    }
}
