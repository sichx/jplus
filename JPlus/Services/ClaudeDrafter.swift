import Foundation

/// A ticket suggestion produced from a screenshot.
struct TicketDraft: Decodable, Sendable {
    let summary: String
    let description: String
    let issueType: String
}

/// Turns a screenshot plus optional notes into a summary, description and type.
struct ClaudeDrafter: Sendable {
    let apiKey: String

    func draft(screenshotPNG: Data, notes: String, projectKey: String, projectName: String?, issueTypeNames: [String]) async throws -> TicketDraft {
        let typeList = issueTypeNames.isEmpty ? ["Bug", "Task"] : issueTypeNames
        let project = projectName.map { "\(projectKey) (\($0))" } ?? projectKey

        let system = """
        You write Jira tickets for the \(project) project from screenshots. Be concrete and only describe \
        what the screenshot and the reporter's notes actually show; never invent steps, causes, or device details. \
        The summary is a single line under 80 characters. The description is plain text: short paragraphs, \
        optional lines starting with "- " for lists, and optional "## " headings such as "What happened", \
        "Where", "Expected", and "Notes". Read any visible text, error messages, screen names, and UI state \
        from the screenshot and quote them where useful. Pick the issue type that fits best from the allowed list.
        """

        var userText = "Draft a Jira ticket for this screenshot. Allowed issue types: \(typeList.joined(separator: ", "))."
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            userText += "\n\nReporter's notes:\n\(trimmedNotes)"
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "description": ["type": "string"],
                "issueType": ["type": "string", "enum": typeList],
            ],
            "required": ["summary", "description", "issueType"],
            "additionalProperties": false,
        ]

        let json = try await ClaudeClient(apiKey: apiKey).structuredJSON(
            system: system,
            content: [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": screenshotPNG.base64EncodedString()]],
                ["type": "text", "text": userText],
            ],
            schema: schema
        )
        do {
            return try JSONDecoder().decode(TicketDraft.self, from: json)
        } catch {
            throw ClaudeError.invalidResponse
        }
    }
}
