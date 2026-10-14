import Foundation

nonisolated struct GitHubOrganization: Codable, Hashable, Sendable {
    static let suggestedURL = "https://volohealth.ghe.com/VOLO-Health"
    let host: String
    let name: String

    init(host: String, name: String) {
        self.host = host
        self.name = name
    }

    /// Also accepts a repository URL so existing connection details can be reused.
    init(url text: String) throws {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { throw GitHubError.invalidOrganization }
        let parts = url.path.split(separator: "/").map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...2).contains(parts.count), let name = parts.first,
              !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { throw GitHubError.invalidOrganization }
        self.host = host
        self.name = name
    }

    var webURL: URL { URL(string: "https://\(host)/\(name)")! }
    var apiURL: URL {
        if host == "github.com" { return URL(string: "https://api.github.com")! }
        if host.hasSuffix(".ghe.com") { return URL(string: "https://api.\(host)")! }
        return URL(string: "https://\(host)/api/v3")!
    }

    func contains(_ repository: GitHubRepository) -> Bool {
        host == repository.host && name.caseInsensitiveCompare(repository.owner) == .orderedSame
    }
}

nonisolated struct GitHubRepository: Codable, Hashable, Sendable {
    static let suggestedURL = "https://volohealth.ghe.com/VOLO-Health/vh-fe-app-ui"

    let host: String
    let owner: String
    let name: String

    init(url text: String) throws {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else {
            throw GitHubError.invalidRepository
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError.invalidRepository }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [parts[0], name].allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw GitHubError.invalidRepository }
        self.host = host
        self.owner = parts[0]
        self.name = name
    }

    var fullName: String { "\(owner)/\(name)" }
    var organization: GitHubOrganization { GitHubOrganization(host: host, name: owner) }
    var webURL: URL { URL(string: "https://\(host)/\(owner)/\(name)")! }
    var apiURL: URL { organization.apiURL }

    func branchURL(_ branch: String) -> URL {
        var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += "/tree/" + GitHubClient.pathSegment(branch)
        return components.url!
    }
}

nonisolated struct GitHubConnection: Codable, Equatable, Sendable {
    let organization: GitHubOrganization
    let token: String

    init(organization: GitHubOrganization, token: String) {
        self.organization = organization
        self.token = token
    }

    private enum CodingKeys: String, CodingKey { case organization, token, repository }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(String.self, forKey: .token)
        if let organization = try values.decodeIfPresent(GitHubOrganization.self, forKey: .organization) {
            self.organization = organization
        } else {
            // Migrate the original repository-bound Keychain entry without asking for a new token.
            organization = try values.decode(GitHubRepository.self, forKey: .repository).organization
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(organization, forKey: .organization)
        try values.encode(token, forKey: .token)
    }
}

nonisolated struct GitHubBranch: Decodable, Identifiable, Sendable {
    let name: String
    var id: String { name }
}

nonisolated enum BranchPrefix: String, CaseIterable, Identifiable, Sendable {
    case bugfix, hotfix, feature, chore, refactor, other
    var id: String { rawValue }

    var pathPrefix: String { self == .other ? "" : "\(rawValue)/" }

    func branchName(_ name: String) -> String { pathPrefix + name }
}

nonisolated enum BranchNaming {
    static let maximumLength = 60

    static func name(issueKey: String, summary: String) -> String {
        let latin = summary.applyingTransform(.toLatin, reverse: false) ?? summary
        let normalized = latin.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let slug = normalized.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Reserve room for every prefix, so switching prefixes keeps an edited name intact.
        let prefixLength = BranchPrefix.allCases.map { $0.pathPrefix.count }.max() ?? 0
        let titleBudget = max(0, maximumLength - prefixLength - issueKey.count - 1)
        var shortened = ""
        for word in slug.split(separator: "-") {
            let candidate = shortened.isEmpty ? String(word) : "\(shortened)-\(word)"
            guard candidate.count <= titleBudget else {
                if shortened.isEmpty { shortened = String(word.prefix(titleBudget)) }
                break
            }
            shortened = candidate
        }
        return shortened.isEmpty ? issueKey : "\(issueKey)-\(shortened)"
    }

    /// Length limits apply to new branches, not existing base branches in the repository.
    static func creationValidationMessage(_ branch: String) -> String? {
        if branch.count > maximumLength {
            return "Keep the full branch name within \(maximumLength) characters, including the prefix. Shorten the title portion."
        }
        return validationMessage(branch)
    }

    static func checkoutCommand(_ branch: String) -> String {
        let unquoted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        let argument = branch.unicodeScalars.allSatisfy(unquoted.contains)
            ? branch
            : "'" + branch.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "git checkout \(argument)"
    }

    /// Mirrors Git's ref-name restrictions without requiring a local Git installation.
    static func validationMessage(_ branch: String) -> String? {
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard !branch.isEmpty, branch != "@", !branch.hasPrefix("-"),
              !branch.contains(".."), !branch.contains("@{"),
              !branch.unicodeScalars.contains(where: forbidden.contains),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }),
              !branch.hasSuffix(".") else {
            return "Use a valid Git branch name: no spaces, empty path segments, .., @{, or special ref characters."
        }
        return nil
    }

    static func preferredBase(branches: [String], fixVersions: [String], saved: String?, defaultBranch: String) -> String? {
        let available = Set(branches)
        let releases = Set(fixVersions.compactMap { version -> String? in
            let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
            let number = version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
            let candidate = "release/\(number)"
            return available.contains(candidate) ? candidate : nil
        })
        if releases.count == 1 { return releases.first }
        if let saved, available.contains(saved) { return saved }
        return available.contains(defaultBranch) ? defaultBranch : nil
    }
}
