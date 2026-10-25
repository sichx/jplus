import SwiftUI

/// The team's open product questions: one Confluence page holding a
/// checklist, edited just as a day of Daily Priorities is. The page is the
/// site's one "Product Questions" page until another is chosen by its link.
struct ProductQuestionsView: View {
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    /// Link to (or id of) the page, per account.
    @AppStorage("productQuestionsPageURL") private var pageInput = ""
    @State private var model = PrioritiesModel()
    @State private var drafts = PriorityDrafts()
    @State private var isChoosingPage = false
    @State private var pageDraft = ""
    /// Looking for the page by title, when none is set.
    @State private var isFindingPage = false
    /// The search ran and found nothing to use; the user picks instead.
    @State private var findFailureMessage: String?
    @State private var newItemSpot: NewItemSpot?
    /// The item swiped open to show its actions, on iOS.
    @State private var swipedOpenID: String?

    private var pageID: String? { PriorityNaming.pageID(from: pageInput) }
    private var page: PriorityDay? { model.shownDays.first }

    var body: some View {
        content
            .navigationTitle("Product Questions")
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(pageID == nil || model.saving != nil)
                    Button("Choose Page…", systemImage: "doc.badge.gearshape") {
                        pageDraft = pageInput
                        isChoosingPage = true
                    }
                    .disabled(model.saving != nil)
                    .popover(isPresented: $isChoosingPage, arrowEdge: .bottom) { pageChooser }
                    if let url = pageWebURL {
                        Button("Open in Confluence", systemImage: "safari") { openURL(url) }
                            .keyboardShortcut("o", modifiers: [.command, .shift])
                            .help("Open the Product Questions page in Confluence (⇧⌘O)")
                    }
                }
            }
            .loadTask(id: pageID) {
                guard let client = session.client else { return }
                if let pageID {
                    await model.load(client: client, pageID: pageID)
                } else {
                    await findPage(using: client)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                // Ticket links on this site open in the app; anything else goes to the browser.
                if url.host() == session.client?.credentials.siteURL.host(),
                   let key = IssueKey.parse(url.absoluteString) {
                    onOpenIssue(key)
                    return .handled
                }
                return .systemAction
            })
    }

    /// The loaded page's own link, or the saved link if it is one.
    private var pageWebURL: URL? {
        if let page { return page.webURL }
        let saved = pageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.hasPrefix("http") ? URL(string: saved) : nil
    }

    /// Looks for the site's "Product Questions" page and uses it when
    /// there's exactly one; otherwise asks the user to choose.
    private func findPage(using client: JiraClient) async {
        isFindingPage = true
        findFailureMessage = nil
        defer { isFindingPage = false }
        do {
            if let page = try await PriorityNaming.findQuestionsPage(using: client) {
                pageInput = page.webURL(on: client.credentials.siteURL).absoluteString
            } else {
                findFailureMessage = "No single \"\(PriorityNaming.questionsPageTitle)\" page was found on \(client.credentials.siteHost)."
            }
        } catch where error.isCancellation {
            return
        } catch {
            findFailureMessage = "Couldn't search \(client.credentials.siteHost) for the page. \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var content: some View {
        if pageID == nil, isFindingPage {
            ProgressView("Finding the Product Questions page…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pageID == nil {
            ScaledContentUnavailableView {
                Label("Choose a Product Questions Page", systemImage: "questionmark.bubble")
            } description: {
                Text((findFailureMessage.map { $0 + " " } ?? "") + "Paste the link to the Confluence page that lists the questions as a checklist.")
            } actions: {
                Button("Choose Page…") {
                    pageDraft = pageInput
                    isChoosingPage = true
                }
                Button("Search Again") {
                    if let client = session.client { Task { await findPage(using: client) } }
                }
            }
        } else if let page {
            PriorityPane(model: model, drafts: drafts, swipedOpenID: $swipedOpenID) {
                VStack(alignment: .leading, spacing: 28) {
                    if let message = model.errorMessage {
                        PriorityErrorLabel(message: message)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        header(page)
                        PriorityItemList(day: page, model: model, emptyText: "No questions yet.", canAdd: true,
                                         itemName: "question", newItemSpot: $newItemSpot, swipedOpenID: $swipedOpenID)
                    }
                }
            }
        } else if let message = model.errorMessage, !model.isLoading {
            ScaledContentUnavailableView {
                Label("Couldn't Load Product Questions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                // The page may have moved or gone.
                Button("Choose Page…") {
                    pageDraft = pageInput
                    isChoosingPage = true
                }
            }
        } else {
            ProgressView("Loading product questions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The page's title and how many of its questions are done.
    private func header(_ page: PriorityDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(page.title)
                .scaledFont(.title3.weight(.semibold))
            if !page.items.isEmpty {
                Text("\(page.items.count - page.openCount) of \(page.items.count) done")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }

    // MARK: - Page

    private var pageChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Product Questions Page")
                .scaledFont(.headline)
            Text("Paste the Confluence page's link, e.g. …/wiki/spaces/VPE1/pages/123456.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
            TextField("Page link", text: $pageDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(savePage)
            HStack {
                Spacer()
                Button("Cancel") { isChoosingPage = false }
                Button("Use Page", action: savePage)
                    .keyboardShortcut(.defaultAction)
                    .disabled(PriorityNaming.pageID(from: pageDraft) == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func savePage() {
        guard PriorityNaming.pageID(from: pageDraft) != nil else { return }
        pageInput = pageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isChoosingPage = false
    }
}
