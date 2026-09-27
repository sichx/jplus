import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Create an issue from a screenshot: drop/paste/choose an image, fill in
/// the fields (or let Claude draft them), create, attach, open.
struct NewTicketView: View {
    let suggestedProjectKey: String?
    let onCreated: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    @AppStorage("newTicketProjectKey") private var projectKey = "VPE"
    @AppStorage("newTicketIssueTypeName") private var preferredTypeName = "Bug"

    @State private var screenshot: Screenshot?
    @State private var projects: [JiraProject] = []
    @State private var issueTypes: [JiraIssueType] = []
    @State private var issueTypeId = ""
    @State private var summary = ""
    @State private var description = ""
    @State private var notes = ""

    @State private var isDropTargeted = false
    @State private var showingFileImporter = false
    @State private var isLoadingTypes = false
    @State private var isDrafting = false
    @State private var isCreating = false
    @State private var progress: String?
    @State private var errorMessage: String?
    /// Local ⌘V handler, installed while this screen is visible.
    @State private var pasteMonitor: Any?

    private var project: JiraProject? { projects.first { $0.key == projectKey } }

    private var canCreate: Bool {
        !summary.trimmingCharacters(in: .whitespaces).isEmpty
            && !projectKey.isEmpty && !issueTypeId.isEmpty
            && !isCreating && !isDrafting
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
                        .font(.callout)
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
        .onPasteCommand(of: ScreenshotImport.acceptedTypes) { providers in
            Task { await importScreenshot(from: providers) }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                setScreenshot(ScreenshotImport.load(url: url), failureMessage: "That file isn't an image the app can read.")
            }
        }
        .task { await loadProjects() }
        .task(id: projectKey) { await loadIssueTypes() }
        .onAppear(perform: installPasteMonitor)
        .onDisappear(perform: removePasteMonitor)
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
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Drop a screenshot here")
                            .font(.headline)
                        Text("or paste with ⌘V, or choose a file. Tip: ⌃⇧⌘4 captures a region to the clipboard.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .frame(height: 260)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            HStack(spacing: 10) {
                Button("Choose…", systemImage: "folder") { showingFileImporter = true }
                Button("Paste", systemImage: "doc.on.clipboard") {
                    setScreenshot(ScreenshotImport.loadFromPasteboard(), failureMessage: "The clipboard doesn't contain an image.")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                if let screenshot {
                    Button("Remove", systemImage: "xmark.circle") { self.screenshot = nil }
                    Text("\(screenshot.filename) · \(screenshot.sizeDescription)")
                        .font(.caption)
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
            GridRow {
                label("Summary")
                TextField("Summary", text: $summary, prompt: Text("Short, specific title"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            GridRow(alignment: .top) {
                label("Description").padding(.top, 6)
                TextEditor(text: $description)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
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
                        Text("Not sent to Jira; only used when drafting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                    Text(progress).font(.callout).foregroundStyle(.secondary)
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
                Task { await draftWithClaude() }
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
        } else {
            Button("Enable Draft with Claude…", systemImage: "sparkles") { openSettings() }
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

    private func selectIssueType(named name: String) {
        if let match = issueTypes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            issueTypeId = match.id
        } else if let bug = issueTypes.first(where: { $0.name.caseInsensitiveCompare("Bug") == .orderedSame }) {
            issueTypeId = bug.id
        } else {
            issueTypeId = issueTypes.first?.id ?? ""
        }
    }

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
                description: description
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
