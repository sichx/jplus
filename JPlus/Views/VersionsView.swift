import SwiftUI

/// Route pushed when a version is chosen.
struct VersionRoute: Hashable {
    let version: JiraVersion
    let project: JiraProject
}

/// Releases for one project, grouped by state, with progress bars.
struct VersionsView: View {
    /// Project key to preselect when nothing is saved yet (e.g. from recent issues).
    let suggestedProjectKey: String?
    let onOpenVersion: (VersionRoute) -> Void

    @Environment(SessionStore.self) private var session
    @AppStorage("versionsProjectKey") private var projectKey = ""
    @AppStorage("versionsShowArchived") private var showArchived = false

    @State private var projects: [JiraProject] = []
    @State private var versions: [JiraVersion] = []
    @State private var isLoadingProjects = true
    @State private var isLoadingVersions = false
    @State private var errorMessage: String?

    private var project: JiraProject? { projects.first { $0.key == projectKey } }
    private var unreleased: [JiraVersion] { versions.filter { !$0.released && !$0.archived } }
    private var released: [JiraVersion] { versions.filter { $0.released && !$0.archived } }
    private var archived: [JiraVersion] { versions.filter(\.archived) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Versions")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await loadVersions() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(projectKey.isEmpty)
            }
        }
        .task { await loadProjects() }
        .task(id: projectKey) { await loadVersions() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if isLoadingProjects && projects.isEmpty {
                ProgressView().controlSize(.small)
                Text("Loading projects…").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $projectKey) {
                    if projectKey.isEmpty { Text("Choose…").tag("") }
                    ForEach(projects) { project in
                        Text("\(project.key) · \(project.name)").tag(project.key)
                    }
                }
                .frame(maxWidth: 380)
            }
            Spacer()
            Toggle("Show archived", isOn: $showArchived)
                .toggleStyle(.checkbox)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Versions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await loadVersions() } }
            }
        } else if projectKey.isEmpty {
            ContentUnavailableView("Choose a Project", systemImage: "shippingbox",
                                   description: Text("Versions are listed per project."))
        } else if isLoadingVersions && versions.isEmpty {
            ProgressView("Loading versions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            ContentUnavailableView("No Versions", systemImage: "shippingbox",
                                   description: Text("\(projectKey) has no versions yet."))
        } else {
            List {
                section("Unreleased", unreleased)
                section("Released", released)
                if showArchived {
                    section("Archived", archived)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [JiraVersion]) -> some View {
        if !items.isEmpty, let project {
            Section("\(title) (\(items.count))") {
                ForEach(items) { version in
                    Button {
                        onOpenVersion(VersionRoute(version: version, project: project))
                    } label: {
                        VersionRow(version: version)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadProjects() async {
        guard let client = session.client else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        do {
            projects = try await client.projects()
            if project == nil {
                if let suggestedProjectKey, projects.contains(where: { $0.key == suggestedProjectKey }) {
                    projectKey = suggestedProjectKey
                } else if projects.count == 1 {
                    projectKey = projects[0].key
                } else if !projects.contains(where: { $0.key == projectKey }) {
                    projectKey = ""
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadVersions() async {
        guard let client = session.client, !projectKey.isEmpty else {
            versions = []
            return
        }
        isLoadingVersions = true
        errorMessage = nil
        defer { isLoadingVersions = false }
        do {
            versions = try await client.versions(projectKey: projectKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct VersionRow: View {
    let version: JiraVersion

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(version.name).fontWeight(.medium)
                    VersionStateBadge(version: version)
                }
                if let description = version.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .lineLimit(2)
                }
                HStack(spacing: 14) {
                    if let day = version.releaseDay {
                        Label(day.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }
                    if let counts = version.issuesStatusForFixVersion, counts.total > 0 {
                        Text("\(counts.done) of \(counts.total) done")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let counts = version.issuesStatusForFixVersion, counts.total > 0 {
                    VersionProgressBar(counts: counts)
                        .frame(height: 6)
                        .frame(maxWidth: 360)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct VersionStateBadge: View {
    let version: JiraVersion

    private var style: (String, Color) {
        if version.archived { return ("ARCHIVED", .gray) }
        if version.released { return ("RELEASED", .green) }
        if version.isOverdue { return ("OVERDUE", .red) }
        return ("UNRELEASED", .blue)
    }

    var body: some View {
        Text(style.0)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style.1.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(style.1)
    }
}

/// Stacked bar: done / in progress / to do.
struct VersionProgressBar: View {
    let counts: JiraVersion.IssueStatusCounts

    var body: some View {
        GeometryReader { geometry in
            let total = max(counts.total, 1)
            let width = geometry.size.width
            HStack(spacing: 0) {
                Rectangle().fill(.green)
                    .frame(width: width * Double(counts.done) / Double(total))
                Rectangle().fill(.blue)
                    .frame(width: width * Double(counts.inProgress) / Double(total))
                Rectangle().fill(.clear)
            }
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
        }
    }
}
