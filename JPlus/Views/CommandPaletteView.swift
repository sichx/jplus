import SwiftUI

/// ⌘K overlay: search box, grouped suggestions with titles, and a preview of
/// the highlighted result.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    let defaultProjectKey: String?
    let onOpen: (PaletteItem) -> Void
    let onClose: () -> Void

    @Environment(SessionStore.self) private var session
    @FocusState private var fieldFocused: Bool
    @State private var highlighted = 0

    private var items: [PaletteItem] { model.items }

    private var selectedItem: PaletteItem? {
        items.indices.contains(highlighted) ? items[highlighted] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            if let selectedItem {
                Divider()
                PalettePreview(item: selectedItem)
            }
            Divider()
            hints
        }
        .frame(width: 660)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { fieldFocused = true }
        .task {
            // The field isn't in the window on the first pass; focus again once it is.
            try? await Task.sleep(for: .milliseconds(60))
            fieldFocused = true
        }
        .onChange(of: model.query) { highlighted = 0 }
        .onChange(of: items.map(\.id)) { highlighted = min(highlighted, max(items.count - 1, 0)) }
        .task(id: model.query) {
            // Debounce typing before asking Jira.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let client = session.client else { return }
            let found = await model.search(defaultProjectKey: defaultProjectKey, client: client)
            rememberTitles(found)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Issue key, words from a title, or a version", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                if let error = model.searchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if model.isSearching {
                    Text("Searching…").foregroundStyle(.secondary)
                } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type an issue key like VPE-5636, a few words from a title, or a version like v1.17.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No matching issues or versions.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let sections = model.sections
                        let offsets = sectionOffsets(sections)
                        ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, sectionIndex == 0 ? 8 : 12)
                                .padding(.bottom, 2)
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                                let index = offsets[sectionIndex] + itemIndex
                                PaletteRow(item: item, isHighlighted: index == highlighted)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { highlighted = index; openHighlighted() }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 340)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted, anchor: nil) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navigate")
            hint("↩", "open")
            hint("esc", "close")
            Spacer()
            if let project = defaultProjectKey {
                Text("Numbers and versions use \(project)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func sectionOffsets(_ sections: [PaletteSection]) -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for section in sections {
            offsets.append(running)
            running += section.items.count
        }
        return offsets
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }

    private func openHighlighted() {
        if let selectedItem { onOpen(selectedItem) }
    }

    private func rememberTitles(_ issues: [PaletteIssue]) {
        guard let id = session.currentAccountID else { return }
        var titles: [String: String] = [:]
        for issue in issues { if let summary = issue.summary { titles[issue.key] = summary } }
        IssueTitleCache.save(titles, in: AccountDefaults.store(for: id))
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch item {
            case .issue(let issue):
                Group {
                    if let type = issue.typeName {
                        IssueTypeBadge(name: type, iconOnly: true)
                    } else {
                        Image(systemName: "ticket").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18)
                Text(issue.key)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, alignment: .leading)
                Text(issue.summary ?? "Open \(issue.key)")
                    .lineLimit(1)
                    .foregroundStyle(issue.summary == nil ? .secondary : .primary)
                Spacer(minLength: 8)
                if let status = issue.status {
                    StatusBadge(status: status).scaleEffect(0.85)
                }
            case .version(let route):
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(route.version.name)
                    .fontWeight(.medium)
                Text(route.project.key)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let day = route.version.releaseDay {
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VersionStateBadge(version: route.version)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear)
        )
    }
}

// MARK: - Preview

/// Larger view of the highlighted result: full title and key facts.
private struct PalettePreview: View {
    let item: PaletteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item {
            case .issue(let issue):
                HStack(spacing: 8) {
                    if let type = issue.typeName { IssueTypeBadge(name: type) }
                    Text(issue.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let status = issue.status { StatusBadge(status: status) }
                }
                Text(issue.summary ?? "Title not loaded yet. Press Return to open \(issue.key).")
                    .font(.headline)
                    .foregroundStyle(issue.summary == nil ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if issue.assignee != nil || issue.updated != nil {
                    HStack(spacing: 12) {
                        if let assignee = issue.assignee { Label(assignee, systemImage: "person") }
                        if let updated = issue.updated {
                            Label("Updated \(updated.formatted(.relative(presentation: .named)))", systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .version(let route):
                HStack(spacing: 8) {
                    Text(route.version.name).font(.headline)
                    VersionStateBadge(version: route.version)
                    Spacer()
                    Text(route.project.name).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let day = route.version.releaseDay {
                        Label("Release \(day.formatted(date: .abbreviated, time: .omitted))", systemImage: "flag.checkered")
                    }
                    if let counts = route.version.issuesStatusForFixVersion, counts.total > 0 {
                        Label("\(counts.done) of \(counts.total) issues done", systemImage: "checklist")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let counts = route.version.issuesStatusForFixVersion, counts.total > 0 {
                    VersionProgressBar(counts: counts)
                        .frame(height: 6)
                        .frame(maxWidth: 360)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
