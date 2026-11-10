#if os(macOS)
import AppKit
#else
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers

/// Create an issue from a screenshot: drop/paste/choose an image, fill in
/// the fields (or let Claude draft them), create, attach, open.
struct NewTicketView: View {
    let suggestedProjectKey: String?
    let onCreated: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openAppSettings) private var openSettings

    @AppStorage("newTicketProjectKey") private var projectKey = "VPE"
    @AppStorage("newTicketIssueTypeName") private var preferredTypeName = "Bug"

    @State private var screenshot: Screenshot?
    @State private var projects: [JiraProject] = []
    @State private var issueTypes: [JiraIssueType] = []
    @State private var issueTypeId = ""
    @State private var summary = ""
    @State private var description = ""
    @State private var notes = ""
    /// The project's unreleased versions, lowest first ("v1.9" before "v1.17").
    @State private var unreleasedVersions: [JiraVersion] = []
    /// "" for none. Defaults to the lowest unreleased version.
    @State private var fixVersionID = ""
    /// The project `unreleasedVersions` were loaded for.
    @State private var versionsProjectKey: String?
    /// The Team field, defaulting to App Team; nil while loading and on a site without one.
    @State private var team: IssueTeamField?
    @State private var isLoadingTeam = true
    @State private var isPickingTeam = false
    /// Ids of the fields on the create screen for `createFieldsKey`; nil if they couldn't be loaded.
    @State private var createFields: Set<String>?
    @State private var createFieldsKey: String?

    @State private var isDropTargeted = false
    @State private var showingFileImporter = false
    @State private var isLoadingTypes = false
    @State private var isDrafting = false
    /// Asking before the first draft sends anything to Anthropic.
    @State private var confirmsClaudeSharing = false
    /// Set once the user agrees; kept app-wide rather than per account.
    @AppStorage(ClaudeSharing.consentKey, store: .standard) private var allowsClaudeSharing = false
    @State private var isCreating = false
    @State private var progress: String?
    @State private var errorMessage: String?
    /// Local ⌘V handler, installed while this screen is visible.
    #if os(macOS)
    @State private var pasteMonitor: Any?
    #else
    @State private var photoItem: PhotosPickerItem?
    #endif

    /// The team new tickets are given unless another is picked.
    private static let defaultTeamName = "App Team"

    private var project: JiraProject? { projects.first { $0.key == projectKey } }

    private var isLoadingVersions: Bool { versionsProjectKey != projectKey }

    /// Identifies the create screen, which depends on both project and type.
    private var createScreenKey: String { "\(projectKey)/\(issueTypeId)" }

    /// Still loading the default fix version or team, or which fields the
    /// create screen has; creating now could leave them out.
    private var isLoadingFields: Bool {
        isLoadingVersions || isLoadingTeam || createFieldsKey != createScreenKey
    }

    private var canCreate: Bool {
        !summary.trimmingCharacters(in: .whitespaces).isEmpty
            && !projectKey.isEmpty && !issueTypeId.isEmpty
            && !isCreating && !isDrafting && !isLoadingFields
    }

    /// Whether the create screen has this field. Assumed so until known, or
    /// if it couldn't be loaded, so the rows don't flicker in.
    private func isOnCreateScreen(_ fieldID: String) -> Bool {
        guard createFieldsKey == createScreenKey, let createFields else { return true }
        return createFields.contains(fieldID)
    }

    private var showsTeam: Bool {
        isLoadingTeam || team.map { isOnCreateScreen($0.fieldID) } == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                screenshotWell
                fields
                actions
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .scaledFont(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("New Ticket")
        .onDrop(of: ScreenshotImport.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            Task { await importScreenshot(from: providers) }
            return true
        }
        #if os(macOS)
        .onPasteCommand(of: ScreenshotImport.acceptedTypes) { providers in
            Task { await importScreenshot(from: providers) }
        }
        #endif
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                setScreenshot(ScreenshotImport.load(url: url), failureMessage: "That file isn't an image the app can read.")
            }
        }
        .loadTask { await loadProjects() }
        .loadTask { await loadDefaultTeam() }
        .task(id: projectKey) { await loadIssueTypes() }
        .task(id: projectKey) { await loadVersions() }
        .task(id: createScreenKey) { await loadCreateFields() }
        #if os(macOS)
        .onAppear(perform: installPasteMonitor)
        .onDisappear(perform: removePasteMonitor)
        #else
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task { await importPhoto(photoItem) }
        }
        #endif
    }

    // MARK: - Screenshot

    private var screenshotWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: screenshot == nil ? [6, 4] : []))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                    )

                if let screenshot, let image = screenshot.image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .scaledFont(.system(size: 34))
                            .foregroundStyle(.secondary)
                        #if os(macOS)
                        Text("Drop a screenshot here")
                            .scaledFont(.headline)
                        Text("or paste with ⌘V, or choose a file. Tip: ⌃⇧⌘4 captures a region to the clipboard.")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #else
                        Text("Add a screenshot")
                            .scaledFont(.headline)
                        Text("Choose one from Photos or Files, or paste one you've copied.")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #endif
                    }
                    .padding()
                }
            }
            .frame(height: 260)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            HStack(spacing: 10) {
                #if os(iOS)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photos", systemImage: "photo")
                }
                #endif
                Button("Choose…", systemImage: "folder") { showingFileImporter = true }
                Button("Paste", systemImage: "doc.on.clipboard") {
                    setScreenshot(ScreenshotImport.loadFromPasteboard(), failureMessage: "The clipboard doesn't contain an image.")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                if let screenshot {
                    Button("Remove", systemImage: "xmark.circle") { self.screenshot = nil }
                    Text("\(screenshot.filename) · \(screenshot.sizeDescription)")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                draftButton
                    .controlSize(.regular)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Fields

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                label("Project")
                HStack {
                    Picker("Project", selection: $projectKey) {
                        if project == nil { Text(projectKey.isEmpty ? "Choose…" : projectKey).tag(projectKey) }
                        ForEach(projects) { project in
                            Text("\(project.key) · \(project.name)").tag(project.key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    Picker("Type", selection: $issueTypeId) {
                        if issueTypes.isEmpty { Text(isLoadingTypes ? "Loading…" : "—").tag("") }
                        ForEach(issueTypes) { type in
                            Text(type.name).tag(type.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .disabled(issueTypes.isEmpty)
                    .onChange(of: issueTypeId) {
                        if let name = issueTypes.first(where: { $0.id == issueTypeId })?.name {
                            preferredTypeName = name
                        }
                    }
                }
            }
            if isOnCreateScreen("fixVersions") {
                GridRow {
                    label("Fix version")
                    Picker("Fix version", selection: $fixVersionID) {
                        Text(isLoadingVersions ? "Loading…" : "None").tag("")
                        if !unreleasedVersions.isEmpty { Divider() }
                        ForEach(unreleasedVersions) { version in
                            Text(version.name).tag(version.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .disabled(isLoadingVersions)
                }
            }
            if showsTeam {
                GridRow {
                    label("Team")
                    teamButton
                }
            }
            GridRow {
                label("Summary")
                TextField("Summary", text: $summary, prompt: Text("Short, specific title"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            GridRow(alignment: .top) {
                label("Description").padding(.top, 6)
                TextEditor(text: $description)
                    .scaledFont(.body)
                    .frame(minHeight: 160)
                    .padding(4)
                    .background(Color.textBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if settings.hasClaudeAPIKey {
                GridRow(alignment: .top) {
                    label("Notes for Claude").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Notes", text: $notes, prompt: Text("Optional context: what you expected, steps, device…"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .lineLimit(2...5)
                        Text("Not sent to Jira; sent to Anthropic only when you draft.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Looks like the pickers above it, but opens the team search, since a
    /// site can have more teams than fit in a menu.
    private var teamButton: some View {
        Button {
            isPickingTeam = true
        } label: {
            HStack(spacing: 6) {
                if isLoadingTeam {
                    Text("Loading…")
                } else if let chosen = team?.team {
                    Label(chosen.name, systemImage: "person.2.fill")
                } else {
                    Text("None")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .disabled(isLoadingTeam)
        .popover(isPresented: $isPickingTeam, arrowEdge: .bottom) {
            TeamPicker(selected: team?.team, isPresented: $isPickingTeam) { chosen in
                team?.team = chosen
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Spacer()

            if let progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).scaledFont(.callout).foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await create() }
            } label: {
                Text(screenshot == nil ? "Create Ticket" : "Create Ticket with Screenshot")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCreate)
            .help("Create (⌘↩)")
        }
    }

    /// Draft with Claude, shown beside the screenshot controls.
    @ViewBuilder
    private var draftButton: some View {
        if settings.hasClaudeAPIKey {
            Button {
                if allowsClaudeSharing {
                    Task { await draftWithClaude() }
                } else {
                    confirmsClaudeSharing = true
                }
            } label: {
                if isDrafting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Drafting…")
                    }
                } else {
                    Label("Draft with Claude", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(screenshot == nil || isDrafting || isCreating)
            .help(screenshot == nil ? "Add a screenshot first" : "Fill summary, description and type from the screenshot")
            .alert("Send to Anthropic?", isPresented: $confirmsClaudeSharing) {
                Button("Send") {
                    allowsClaudeSharing = true
                    Task { await draftWithClaude() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ClaudeSharing.consentMessage)
            }
        } else {
            Button("Enable Draft with Claude…", systemImage: "sparkles") {
                SettingsPage.select(.ai)
                openSettings()
            }
                .help("Add a Claude API key in Settings")
        }
    }

    // MARK: - Loading

    private func loadProjects() async {
        guard let client = session.client else { return }
        do {
            projects = try await client.projects()
            if project == nil {
                if let suggestedProjectKey, projects.contains(where: { $0.key == suggestedProjectKey }) {
                    projectKey = suggestedProjectKey
                } else if !projects.contains(where: { $0.key == projectKey }), let first = projects.first {
                    projectKey = first.key
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadIssueTypes() async {
        guard let client = session.client, !projectKey.isEmpty else {
            issueTypes = []
            issueTypeId = ""
            return
        }
        isLoadingTypes = true
        defer { isLoadingTypes = false }
        do {
            let detail = try await client.projectDetail(key: projectKey)
            issueTypes = detail.issueTypes.filter { !$0.subtask }
            selectIssueType(named: preferredTypeName)
        } catch {
            issueTypes = []
            issueTypeId = ""
            errorMessage = error.localizedDescription
        }
    }

    /// The project's unreleased versions, picking the lowest. Results for a
    /// project that is no longer chosen are dropped.
    private func loadVersions() async {
        let key = projectKey
        unreleasedVersions = []
        fixVersionID = ""
        guard let client = session.client, !key.isEmpty else {
            versionsProjectKey = key
            return
        }
        let versions: [JiraVersion]
        do {
            versions = try await client.versionsWithoutCounts(projectKey: key)
        } catch {
            guard !Task.isCancelled, key == projectKey else { return }
            versions = []
            errorMessage = "Couldn't load versions: \(error.localizedDescription)"
        }
        guard !Task.isCancelled, key == projectKey else { return }
        unreleasedVersions = versions
            .filter { !$0.released && !$0.archived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        fixVersionID = unreleasedVersions.first?.id ?? ""
        versionsProjectKey = key
    }

    /// Finds the Team field and the default team. Without either the ticket
    /// is created with no team.
    private func loadDefaultTeam() async {
        defer { isLoadingTeam = false }
        guard let client = session.client, let fieldID = try? await session.teamFieldID() else { return }
        var field = IssueTeamField(fieldID: fieldID)
        if let cloudId = try? await session.cloudId(),
           let orgId = try? await session.orgId(),
           let found = try? await client.teams(matching: Self.defaultTeamName, orgId: orgId, cloudId: cloudId) {
            // The search is fuzzy, so it may also find "App Server Team".
            field.team = found.first { $0.name.caseInsensitiveCompare(Self.defaultTeamName) == .orderedSame }
        }
        team = field
    }

    private func loadCreateFields() async {
        let key = createScreenKey
        guard let client = session.client, !projectKey.isEmpty, !issueTypeId.isEmpty else { return }
        let fields = try? await client.createFieldIDs(projectKey: projectKey, issueTypeId: issueTypeId)
        guard !Task.isCancelled, key == createScreenKey else { return }
        createFields = fields
        createFieldsKey = key
    }

    private func selectIssueType(named name: String) {
        if let match = issueTypes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            issueTypeId = match.id
        } else if let bug = issueTypes.first(where: { $0.name.caseInsensitiveCompare("Bug") == .orderedSame }) {
            issueTypeId = bug.id
        } else {
            issueTypeId = issueTypes.first?.id ?? ""
        }
    }

    #if os(macOS)
    // MARK: - ⌘V

    /// ⌘V normally goes to whichever text field has focus, and a text field
    /// can't take an image. This catches ⌘V first and attaches the image when
    /// the clipboard holds one, letting ordinary text pastes through.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                let isEditingText = event.window?.firstResponder is NSText
                guard ScreenshotImport.shouldPasteImage(isEditingText: isEditingText) else { return false }
                setScreenshot(ScreenshotImport.loadFromPasteboard(), failureMessage: "The clipboard image couldn't be read.")
                return true
            }
            return handled ? nil : event
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
    #else
    // MARK: - Photos

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
        let data = try? await item.loadTransferable(type: Data.self)
        setScreenshot(data.flatMap { Screenshot(data: $0, filename: "Photo.\(ext)") },
                      failureMessage: "That photo couldn't be read.")
    }
    #endif

    // MARK: - Screenshot import

    private func importScreenshot(from providers: [NSItemProvider]) async {
        let shot = await ScreenshotImport.load(from: providers)
        setScreenshot(shot, failureMessage: "That doesn't look like an image.")
    }

    private func setScreenshot(_ shot: Screenshot?, failureMessage: String) {
        if let shot {
            screenshot = shot
            errorMessage = nil
        } else {
            errorMessage = failureMessage
        }
    }

    // MARK: - Draft

    private func draftWithClaude() async {
        guard let screenshot, let png = screenshot.pngForAnalysis() else { return }
        guard settings.hasClaudeAPIKey else {
            errorMessage = ClaudeError.missingAPIKey.localizedDescription
            return
        }
        isDrafting = true
        errorMessage = nil
        defer { isDrafting = false }
        do {
            let drafter = ClaudeDrafter(apiKey: settings.claudeAPIKey)
            let draft = try await drafter.draft(
                screenshotPNG: png,
                notes: notes,
                projectKey: projectKey,
                projectName: project?.name,
                issueTypeNames: issueTypes.map(\.name)
            )
            summary = draft.summary
            description = draft.description
            selectIssueType(named: draft.issueType)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create

    private func create() async {
        guard let client = session.client, canCreate else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false; progress = nil }

        let created: CreatedIssue
        do {
            progress = "Creating issue…"
            created = try await client.createIssue(
                projectKey: projectKey,
                issueTypeId: issueTypeId,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description,
                fixVersionID: isOnCreateScreen("fixVersions") && !fixVersionID.isEmpty ? fixVersionID : nil,
                team: team.flatMap { isOnCreateScreen($0.fieldID) ? $0 : nil }
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if let screenshot {
            progress = "Uploading screenshot to \(created.key)…"
            do {
                try await client.attach(screenshot.data, filename: screenshot.filename, mimeType: screenshot.mimeType, to: created.key)
            } catch {
                // The issue exists; report the partial failure rather than losing it.
                errorMessage = "Created \(created.key), but the screenshot upload failed: \(error.localizedDescription)"
                onCreated(created.key)
                return
            }
        }

        summary = ""
        description = ""
        notes = ""
        self.screenshot = nil
        onCreated(created.key)
    }
}
