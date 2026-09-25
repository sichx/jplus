import Foundation

/// A ticket suggestion produced from a screenshot.
struct TicketDraft: Decodable, Sendable {
    let summary: String
    let description: String
    let issueType: String
}

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case refused
    case truncated
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add a Claude API key in Settings to draft tickets from screenshots."
        case .http(let status, let message): return "Claude API error \(status): \(message)"
        case .refused: return "Claude declined to describe this screenshot."
        case .truncated: return "Claude's draft was cut off. Try again."
        case .invalidResponse: return "Couldn't read Claude's response."
        }
    }
}

/// Calls the Claude Messages API directly (no Swift SDK) to turn a
/// screenshot plus optional notes into a summary, description and type.
struct ClaudeDrafter: Sendable {
    let apiKey: String
    static let model = "claude-opus-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

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

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            // Server-side refusal fallback: if this model declines, the API retries on a suitable one.
            "fallbacks": "default",
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": screenshotPNG.base64EncodedString()]],
                    ["type": "text", "text": userText],
                ],
            ]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data))?.error.message ?? "Unexpected response."
            throw ClaudeError.http(status: http.statusCode, message: message)
        }

        let message = try decoder.decode(MessagesResponse.self, from: data)
        switch message.stopReason {
        case "refusal": throw ClaudeError.refused
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8)
        else { throw ClaudeError.invalidResponse }

        do {
            return try JSONDecoder().decode(TicketDraft.self, from: json)
        } catch {
            throw ClaudeError.invalidResponse
        }
    }

    private struct MessagesResponse: Decodable {
        let stopReason: String?
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError
        struct APIError: Decodable {
            let type: String?
            let message: String
        }
    }
}
