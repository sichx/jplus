import Foundation
import Observation

/// App-level settings that aren't tied to the Jira session.
@Observable
final class SettingsStore {
    private(set) var claudeAPIKey = ""
    private(set) var isLoaded = false

    var hasClaudeAPIKey: Bool { !claudeAPIKey.isEmpty }

    private let keychain = KeychainStore(service: "co.interactivelabs.jplus", account: "anthropic-api-key")

    func load() async {
        guard !isLoaded else { return }
        let keychain = self.keychain
        let data = await Task.detached { try? keychain.load() }.value
        claudeAPIKey = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        isLoaded = true
    }

    func saveClaudeAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychain = self.keychain
        if trimmed.isEmpty {
            try await Task.detached { try keychain.delete() }.value
        } else {
            let data = Data(trimmed.utf8)
            try await Task.detached { try keychain.save(data) }.value
        }
        claudeAPIKey = trimmed
    }
}
