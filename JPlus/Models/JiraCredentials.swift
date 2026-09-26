import Foundation

/// Everything needed to talk to one Jira Cloud site as one user.
/// Persisted as a single JSON blob in the Keychain.
struct JiraCredentials: Codable, Hashable, Sendable {
    /// Site origin only, e.g. `https://acme.atlassian.net`.
    var siteURL: URL
    var email: String
    var apiToken: String

    /// Jira Cloud API tokens use HTTP Basic auth with `email:token`.
    var authorizationHeader: String {
        let raw = "\(email):\(apiToken)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    var siteHost: String { siteURL.host() ?? siteURL.absoluteString }
}

enum JiraSite {
    /// Accepts "acme", "acme.atlassian.net", "https://acme.atlassian.net/jira/…"
    /// and returns the canonical https origin, or nil if it can't be a host.
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }

        guard var components = URLComponents(string: text),
              var host = components.host, !host.isEmpty
        else { return nil }

        if !host.contains(".") { host += ".atlassian.net" }

        components.scheme = "https"
        components.host = host
        components.port = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}
