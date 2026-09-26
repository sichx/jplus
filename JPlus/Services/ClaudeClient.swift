import Foundation

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case refused
    case truncated
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add a Claude API key on the Account screen or in Settings."
        case .http(let status, let message): return "Claude API error \(status): \(message)"
        case .refused: return "Claude declined this request."
        case .truncated: return "Claude's answer was cut off. Try again."
        case .invalidResponse: return "Couldn't read Claude's response."
        }
    }
}

/// Minimal Claude Messages API client over raw HTTP (there is no official
/// Swift SDK). Every call asks for JSON matching a schema.
struct ClaudeClient: Sendable {
    let apiKey: String
    static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sends one user turn and returns the JSON text of the structured reply.
    func structuredJSON(system: String, content: [[String: Any]], schema: [String: Any], maxTokens: Int = 16000) async throws -> Data {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "system": system,
            // Server-side refusal fallback: if this model declines, the API retries on a suitable one.
            "fallbacks": "default",
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
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
        guard let text = message.content.last(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8)
        else { throw ClaudeError.invalidResponse }
        return json
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
