import SwiftUI

/// "Effort estimate" card on the issue detail. Runs only on request.
struct EffortEstimateView: View {
    let issue: JiraIssue

    @Environment(SessionStore.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    @State private var saved: SavedEstimate?
    @State private var isEstimating = false
    @State private var errorMessage: String?
    @State private var showDetails = false

    private var defaults: UserDefaults? {
        session.currentAccountID.map(AccountDefaults.store(for:))
    }

    private var isStale: Bool {
        guard let saved else { return false }
        return issue.fields.updated > saved.issueUpdatedAt.addingTimeInterval(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let saved {
                result(saved)
            } else if !isEstimating {
                Text("Ask Claude how long this ticket would take one engineer, based on its description and discussion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isEstimating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading the ticket…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            if let defaults { saved = EstimateCache.load(issue.key, from: defaults) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Effort estimate", systemImage: "sparkles")
                .font(.headline)
            Text("one engineer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if settings.hasClaudeAPIKey {
                Button {
                    Task { await estimate() }
                } label: {
                    Label(saved == nil ? "Estimate with Claude" : "Re-estimate",
                          systemImage: saved == nil ? "sparkles" : "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isEstimating)
                .help("Sends this ticket's text and comments to Claude")
            } else {
                Button("Add Claude API Key…") { openSettings() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Result

    private func result(_ saved: SavedEstimate) -> some View {
        let estimate = saved.estimate
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Self.format(days: estimate.likelyDays))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Range \(Self.format(days: estimate.optimisticDays)) – \(Self.format(days: estimate.pessimisticDays))")
                        .font(.callout)
                    Text("Working time for one engineer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SizeBadge(size: estimate.size)
                ConfidenceBadge(confidence: estimate.confidence)
            }

            Text(estimate.summary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    if !estimate.breakdown.isEmpty {
                        detailBlock("Breakdown") {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                                ForEach(Array(estimate.breakdown.enumerated()), id: \.offset) { _, item in
                                    GridRow {
                                        Text(item.task).fixedSize(horizontal: false, vertical: true)
                                        Text(Self.format(days: item.days))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .gridColumnAlignment(.trailing)
                                    }
                                }
                            }
                        }
                    }
                    bulletBlock("Assumptions", estimate.assumptions)
                    bulletBlock("Risks", estimate.risks)
                    bulletBlock("Open questions", estimate.openQuestions)
                }
                .font(.callout)
                .textSelection(.enabled)
                .padding(.top, 6)
            } label: {
                Text(showDetails ? "Hide details" : "Breakdown, assumptions and risks")
                    .font(.callout)
            }

            HStack(spacing: 6) {
                if isStale {
                    Label("Ticket changed since this estimate", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text("Estimated \(saved.createdAt.formatted(.relative(presentation: .named))) from the ticket text only")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func detailBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            content()
        }
    }

    @ViewBuilder
    private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            detailBlock(title) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action

    private func estimate() async {
        guard settings.hasClaudeAPIKey else {
            errorMessage = ClaudeError.missingAPIKey.localizedDescription
            return
        }
        isEstimating = true
        errorMessage = nil
        defer { isEstimating = false }
        do {
            let estimate = try await EffortEstimator(apiKey: settings.claudeAPIKey).estimate(issue)
            let result = SavedEstimate(estimate: estimate, createdAt: .now, issueUpdatedAt: issue.fields.updated, model: ClaudeClient.model)
            saved = result
            if let defaults { EstimateCache.save(result, for: issue.key, in: defaults) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Formatting

    /// "2h", "0.5 day", "3 days", "1.5 days".
    static func format(days: Double) -> String {
        if days < 0.5 {
            let hours = max(1, (days * 8).rounded())
            return "\(Int(hours))h"
        }
        let rounded = (days * 2).rounded() / 2
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return rounded == 1 ? "1 day" : "\(number) days"
    }
}

private struct SizeBadge: View {
    let size: String

    var body: some View {
        Text(size)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Color.accentColor)
            .help("T-shirt size")
    }
}

private struct ConfidenceBadge: View {
    let confidence: String

    private var color: Color {
        switch confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }

    var body: some View {
        Label("\(confidence.capitalized) confidence", systemImage: "gauge.with.dots.needle.33percent")
            .font(.caption)
            .foregroundStyle(color)
    }
}
