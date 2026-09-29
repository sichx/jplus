import Foundation

/// Cursor clipboard prompts for bugs vs feature-shaped tickets.
enum IssueCursorPromptKind: Sendable {
    case debug
    case featurePlanning

    static func forIssue(_ issue: JiraIssue) -> IssueCursorPromptKind? {
        let name = issue.fields.issueType.name.lowercased()
        if name.contains("bug") { return .debug }
        if name.contains("story") || name.contains("feature") || name.contains("epic") {
            return .featurePlanning
        }
        return nil
    }

    var buttonTitle: String {
        switch self {
        case .debug: "Debug Prompt"
        case .featurePlanning: "Feature Planning Prompt"
        }
    }

    var systemImage: String {
        switch self {
        case .debug: "ladybug"
        case .featurePlanning: "list.bullet.clipboard"
        }
    }
}

enum IssueCursorPrompts {
    static func text(for issue: JiraIssue, kind: IssueCursorPromptKind) -> String {
        let ticketKey = issue.key
        let ticketDetails = ticketDetailsBlock(for: issue)
        switch kind {
        case .debug:
            return """
            You are debugging Jira bug \(ticketKey). This workspace contains all related repositories for our product, including both application/code repositories and ClickHouse database schema/migration repositories. Treat these as parts of the same system and search across them as needed.

            Ticket details

            \(ticketDetails)

            What to do

            1. Understand the reported and expected behavior from the ticket details above.
            2. Locate the relevant code paths and ClickHouse/database definitions across repos. Trace the flow between application code, queries, tables, views, and schemas as needed. Cite repositories, files, and symbols.
            3. Determine the root cause with evidence, not guesses. Check for mismatches between code/queries and the ClickHouse schema, migrations, types, views, or data assumptions. Note repro steps or how you would verify locally.
            4. Propose a minimal fix, including which repo(s) need changes, relevant edge cases, and tests or manual verification.
            5. If information is missing, state assumptions and what you would ask the reporter.

            Be systematic: read the ticket first, then investigate. Search all relevant repos before concluding the issue is isolated to one. Prefer small, targeted changes and clearly distinguish confirmed findings from assumptions.
            """
        case .featurePlanning:
            return """
            You are planning a Jira feature in Cursor. This workspace contains all related repositories for our product—use them to inform a realistic plan.

            **Do not implement yet.** Do not edit production code, create commits, or write plan documents to the repo until the user explicitly approves your plan. Read-only exploration and planning only.

            Ticket details

            \(ticketDetails)

            ## What to deliver (planning only)
            Write the implementation plan **in this chat** as your reply—do not create markdown files, ADRs, or other planning docs in the workspace unless the user asks. Produce a written plan for user review:

            1. **Goal & success criteria** — what “done” means per the ticket.
            2. **Scope** — in scope, out of scope, and dependencies on other work.
            3. **Repos & touchpoints** — which repositories and subsystems are likely involved.
            4. **Design** — APIs, data model, UI/UX, config, migrations, feature flags if any.
            5. **Step-by-step execution** — ordered, reviewable tasks (rough sizing optional).
            6. **Testing & rollout** — unit/integration tests, QA, monitoring, rollback.
            7. **Risks & open questions** — ambiguities to resolve with the user before coding.

            Ask clarifying questions where the ticket is vague. **Wait for explicit user approval before implementing anything or adding files.**
            """
        }
    }

    /// Summary, description, and comments — no status/assignee/dates metadata.
    private static func ticketDetailsBlock(for issue: JiraIssue) -> String {
        let fields = issue.fields
        var lines = [
            "Key: \(issue.key)",
            "Summary: \(fields.summary)",
        ]

        let description = fields.description?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines += ["", "Description:", description.isEmpty ? "(none)" : description]

        let comments = fields.comment?.comments ?? []
        if !comments.isEmpty {
            lines += ["", "Comments:"]
            for comment in comments {
                let body = comment.body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let author = comment.author?.displayName ?? "Unknown"
                lines.append("- \(author): \(body)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
