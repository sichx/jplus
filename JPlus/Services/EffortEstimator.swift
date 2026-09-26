import Foundation

/// Claude's estimate of how long one engineer needs to finish a ticket.
struct EffortEstimate: Codable, Hashable, Sendable {
    let summary: String
    let size: String
    let confidence: String
    let optimisticDays: Double
    let likelyDays: Double
    let pessimisticDays: Double
    let breakdown: [Task]
    let assumptions: [String]
    let risks: [String]
    let openQuestions: [String]

    struct Task: Codable, Hashable, Sendable {
        let task: String
        let days: Double
    }
}

/// An estimate plus when it was made and which version of the ticket it saw.
struct SavedEstimate: Codable, Hashable, Sendable {
    let estimate: EffortEstimate
    let createdAt: Date
    let issueUpdatedAt: Date
    let model: String
}

/// Asks Claude to size a ticket for a single engineer.
struct EffortEstimator: Sendable {
    let apiKey: String

    static let sizes = ["XS", "S", "M", "L", "XL"]
    static let confidences = ["low", "medium", "high"]

    func estimate(_ issue: JiraIssue) async throws -> EffortEstimate {
        let system = """
        You estimate engineering effort for Jira tickets. Estimate how many working days one engineer needs \
        to finish the ticket: an experienced engineer who already knows the codebase, working focused days. \
        Count design, implementation, tests, code review changes and verification. Do not count time waiting \
        on other people, QA cycles, release trains, or unrelated meetings.

        You only have the ticket text, not the codebase. Base the estimate on the scope the ticket describes, \
        say which assumptions carry the most weight, and lower your confidence when the ticket is vague, \
        when important details are missing, or when the work depends on systems the ticket does not explain. \
        If the discussion shows work is already partly done, estimate only the remaining work and say so.

        Units are working days; use fractions like 0.25 for two hours. The optimistic, likely and pessimistic \
        values must be in increasing order, and the breakdown tasks should roughly add up to the likely value. \
        Size guide: XS under half a day, S up to 2 days, M up to 5 days, L up to 10 days, XL more than 10 days. \
        Keep the summary to one or two sentences. Keep each list item short and specific to this ticket.
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "size": ["type": "string", "enum": Self.sizes],
                "confidence": ["type": "string", "enum": Self.confidences],
                "optimisticDays": ["type": "number"],
                "likelyDays": ["type": "number"],
                "pessimisticDays": ["type": "number"],
                "breakdown": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["task": ["type": "string"], "days": ["type": "number"]],
                        "required": ["task", "days"],
                        "additionalProperties": false,
                    ],
                ],
                "assumptions": ["type": "array", "items": ["type": "string"]],
                "risks": ["type": "array", "items": ["type": "string"]],
                "openQuestions": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["summary", "size", "confidence", "optimisticDays", "likelyDays", "pessimisticDays",
                         "breakdown", "assumptions", "risks", "openQuestions"],
            "additionalProperties": false,
        ]

        let json = try await ClaudeClient(apiKey: apiKey).structuredJSON(
            system: system,
            content: [["type": "text", "text": Self.describe(issue)]],
            schema: schema
        )
        do {
            return try JSONDecoder().decode(EffortEstimate.self, from: json)
        } catch {
            throw ClaudeError.invalidResponse
        }
    }

    /// The ticket as plain text for the prompt. Nothing is shortened.
    static func describe(_ issue: JiraIssue) -> String {
        let fields = issue.fields
        var lines = [
            "Estimate the effort for this Jira ticket.",
            "",
            "Key: \(issue.key)",
            "Type: \(fields.issueType.name)",
            "Status: \(fields.status.name)",
            "Summary: \(fields.summary)",
        ]
        if let priority = fields.priority { lines.append("Priority: \(priority.name)") }
        if let parent = fields.parent {
            lines.append("Parent: \(parent.key) \(parent.fields?.summary ?? "")")
        }
        if !fields.labels.isEmpty { lines.append("Labels: \(fields.labels.joined(separator: ", "))") }
        if !fields.components.isEmpty { lines.append("Components: \(fields.components.map(\.name).joined(separator: ", "))") }

        let description = fields.description?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines += ["", "Description:", description.isEmpty ? "(none)" : description]

        let comments = fields.comment?.comments ?? []
        if !comments.isEmpty {
            lines += ["", "Discussion (oldest first):"]
            for comment in comments {
                let body = comment.body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let author = comment.author?.displayName ?? "Unknown"
                lines.append("- \(author), \(comment.created.formatted(date: .abbreviated, time: .omitted)): \(body)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Saved estimates for one account, keyed by issue key.
enum EstimateCache {
    private static let key = "effortEstimates"

    static func load(_ issueKey: String, from defaults: UserDefaults) -> SavedEstimate? {
        all(in: defaults)[issueKey]
    }

    static func save(_ saved: SavedEstimate, for issueKey: String, in defaults: UserDefaults) {
        var entries = all(in: defaults)
        entries[issueKey] = saved
        // Keep the 300 most recent so the defaults file stays small.
        if entries.count > 300 {
            let keep = entries.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(300)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private static func all(in defaults: UserDefaults) -> [String: SavedEstimate] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedEstimate].self, from: data)) ?? [:]
    }
}
