import Foundation

/// Which Ask AI prompt a ticket gets, from its issue type. Done tickets get
/// none: there's nothing left to debug or build.
enum IssueAIPromptKind: Sendable {
    /// Bugs: find the root cause and propose a fix.
    case debug
    /// Stories, features and epics: plan the feature.
    case featurePlanning
    /// Spikes and research tickets: investigate and report options, no code.
    case research
    /// Sub-tasks: plan just this piece, in the context of its parent.
    case subtask
    /// Tasks, improvements and any other type: plan the change.
    case implementation

    static func forIssue(_ issue: JiraIssue) -> IssueAIPromptKind? {
        guard !issue.fields.status.isDone else { return nil }
        let type = issue.fields.issueType
        let name = type.name.lowercased()
        if name.contains("bug") || name.contains("defect") { return .debug }
        if type.subtask == true || (type.hierarchyLevel ?? 0) < 0 { return .subtask }
        if name.contains("spike") || name.contains("research") { return .research }
        if type.isEpicLevel || name.contains("story") || name.contains("feature") { return .featurePlanning }
        return .implementation
    }

    /// What the prompt asks for, shown under the Ask AI… button.
    var summary: String {
        switch self {
        case .debug: "Debug this bug"
        case .featurePlanning: "Plan this feature"
        case .research: "Research this spike"
        case .subtask: "Plan this sub-task"
        case .implementation: "Plan this change"
        }
    }
}

enum IssueAIPrompts {
    static func text(for issue: JiraIssue, kind: IssueAIPromptKind) -> String {
        let key = issue.key
        let details = ticketDetailsBlock(for: issue)
        switch kind {
        case .debug:
            return """
            You are debugging Jira bug \(key). This workspace contains all related repositories for our product, including both application/code repositories and ClickHouse database schema/migration repositories. Treat these as parts of the same system and search across them as needed.

            **Present a plan first. Do not implement yet.** Do not edit code, create commits, or write files until the user explicitly approves your plan. Investigation is read-only until then.

            Ticket details

            \(details)

            What to do

            1. Understand the reported and expected behavior from the ticket details above.
            2. Locate the relevant code paths and ClickHouse/database definitions across repos. Trace the flow between application code, queries, tables, views, and schemas as needed. Cite repositories, files, and symbols.
            3. Determine the root cause with evidence, not guesses. Check for mismatches between code/queries and the ClickHouse schema, migrations, types, views, or data assumptions. Note repro steps or how you would verify locally.
            4. Propose a minimal fix, including which repo(s) need changes, relevant edge cases, and tests or manual verification.
            5. If information is missing, state assumptions and what you would ask the reporter.

            Be systematic: read the ticket first, then investigate. Search all relevant repos before concluding the issue is isolated to one. Prefer small, targeted changes and clearly distinguish confirmed findings from assumptions.

            Write the plan in this chat as your reply, and wait for explicit user approval before implementing the fix or adding any files.
            """
        case .featurePlanning:
            return """
            You are planning Jira \(issue.fields.issueType.name.lowercased()) \(key). This workspace contains all related repositories for our product—use them to inform a realistic plan.

            **Do not implement yet.** Do not edit production code, create commits, or write plan documents to the repo until the user explicitly approves your plan. Read-only exploration and planning only.

            Ticket details

            \(details)

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
        case .research:
            return """
            You are researching Jira spike \(key). This workspace contains all related repositories for our product, including application code and ClickHouse database schema/migration repositories. The goal of a spike is knowledge, not shipped code.

            **Do not implement anything.** Do not edit code, create commits, or write files. Read-only investigation only; small throwaway experiments only if the user agrees first.

            Ticket details

            \(details)

            ## What to deliver
            Write your findings **in this chat** as your reply:

            1. **Question** — restate what the spike needs to answer, and what a useful answer looks like.
            2. **Current state** — how the relevant parts of the system work today, citing repositories, files, and symbols.
            3. **Options** — realistic approaches, each with pros, cons, rough effort, and risks.
            4. **Recommendation** — which option you'd pick and why.
            5. **Follow-up work** — the tickets you'd create to carry it out.
            6. **Unknowns** — what you couldn't confirm and how to find out.

            Clearly separate confirmed findings from assumptions. Ask clarifying questions where the ticket is vague.
            """
        case .subtask:
            return """
            You are planning Jira sub-task \(key). It is one piece of a larger ticket (the parent below), so keep the plan to this sub-task's scope and fit it into the parent's goal. This workspace contains all related repositories for our product, including application code and ClickHouse database schema/migration repositories.

            **Present a plan first. Do not implement yet.** Do not edit code, create commits, or write files until the user explicitly approves your plan. Investigation is read-only until then.

            Ticket details

            \(details)

            ## What to deliver
            Write the plan **in this chat** as your reply:

            1. **Goal** — what this sub-task delivers, and how it serves the parent ticket.
            2. **Touchpoints** — the repositories, files, and symbols to change, with citations.
            3. **Steps** — ordered, small, reviewable changes.
            4. **Testing** — unit/integration tests or manual verification.
            5. **Boundaries** — related work that belongs to the parent or a sibling sub-task, not this one.
            6. **Open questions** — anything to settle with the user before coding.

            **Wait for explicit user approval before implementing anything or adding files.**
            """
        case .implementation:
            return """
            You are working on Jira \(issue.fields.issueType.name.lowercased()) \(key). This workspace contains all related repositories for our product, including application code and ClickHouse database schema/migration repositories. Treat these as parts of the same system and search across them as needed.

            **Present a plan first. Do not implement yet.** Do not edit code, create commits, or write files until the user explicitly approves your plan. Investigation is read-only until then.

            Ticket details

            \(details)

            ## What to deliver
            Write the plan **in this chat** as your reply:

            1. **Goal & done criteria** — what the ticket asks for and how to tell it's finished.
            2. **Current behavior** — how the relevant code works today, citing repositories, files, and symbols.
            3. **Changes** — what to change in each repo, as ordered, reviewable steps.
            4. **Testing** — unit/integration tests or manual verification.
            5. **Risks & open questions** — edge cases, migrations, and anything to settle with the user before coding.

            Prefer small, targeted changes. **Wait for explicit user approval before implementing anything or adding files.**
            """
        }
    }

    /// Type, summary, parent, sub-tasks (with their status), description and
    /// comments; not the ticket's own status, assignee or dates.
    private static func ticketDetailsBlock(for issue: JiraIssue) -> String {
        let fields = issue.fields
        var lines = [
            "Key: \(issue.key)",
            "Type: \(fields.issueType.name)",
            "Summary: \(fields.summary)",
        ]
        if let parent = fields.parent {
            let summary = parent.fields?.summary.map { " — \($0)" } ?? ""
            lines.append("Parent: \(parent.key)\(summary)")
        }

        let subtasks = fields.subtasks ?? []
        if !subtasks.isEmpty {
            lines += ["", "Sub-tasks:"]
            for subtask in subtasks {
                let summary = subtask.fields?.summary.map { " — \($0)" } ?? ""
                let status = subtask.fields?.status.map { " [\($0.name)]" } ?? ""
                lines.append("- \(subtask.key)\(summary)\(status)")
            }
        }

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
