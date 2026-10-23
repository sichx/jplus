import Foundation

nonisolated enum GitHubError: LocalizedError {
    case invalidRepository
    case invalidOrganization
    case invalidResponse
    case unauthorized
    case missingToken
    case forbidden(String?)
    case notFound
    case http(Int, String?)
    case branchExists
    case invalidBranch(String)
    case readOnlyRepository

    var errorDescription: String? {
        switch self {
        case .invalidRepository: "Enter an HTTPS repository URL such as \(GitHubRepository.suggestedURL)."
        case .invalidOrganization: "Enter an HTTPS organization URL such as \(GitHubOrganization.suggestedURL)."
        case .invalidResponse: "Couldn't read GitHub's response."
        case .unauthorized: "GitHub rejected the token. Check whether it is correct or has expired."
        case .missingToken: "Enter a GitHub personal access token for this repository."
        case .forbidden(let message): "GitHub denied access. Check repository permissions and any required token approval.\(message.map { " \($0)" } ?? "")"
        case .notFound: "Repository or branch not found, or this token doesn't have access."
        case .http(let status, let message): "GitHub error \(status).\(message.map { " \($0)" } ?? "")"
        case .branchExists: "A branch with this name already exists. Choose a different name."
        case .invalidBranch(let message): message
        case .readOnlyRepository: "This repository is archived or disabled and cannot accept new branches."
        }
    }
}

/// Authenticated requests stay on the configured API host; redirects are never followed.
nonisolated private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated struct GitHubClient: Sendable {
    let organization: GitHubOrganization
    private let token: String
    private let session: URLSession
    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }()

    init(organization: GitHubOrganization, token: String, session: URLSession? = nil) {
        self.organization = organization
        self.token = token
        self.session = session ?? Self.liveSession
    }

    struct RepositoryInfo: Decodable, Sendable {
        let defaultBranch: String
        let archived: Bool
        let disabled: Bool
        enum CodingKeys: String, CodingKey {
            case defaultBranch = "default_branch"
            case archived, disabled
        }
    }

    func repositoryInfo(_ repository: GitHubRepository) async throws -> RepositoryInfo {
        try await send(path: repositoryPath(repository))
    }

    /// Lists active repositories visible to the token, without fetching any branches.
    func repositories() async throws -> [GitHubRepository] {
        var result: [GitHubRepository] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let batch: [ListedRepository] = try await send(path: ["orgs", organization.name, "repos"], query: [
                URLQueryItem(name: "type", value: "all"), URLQueryItem(name: "sort", value: "full_name"),
                URLQueryItem(name: "direction", value: "asc"), URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ])
            for item in batch where !item.archived && !item.disabled {
                guard item.owner.login.caseInsensitiveCompare(organization.name) == .orderedSame,
                      let repository = try? GitHubRepository(url: "https://\(organization.host)/\(item.owner.login)/\(item.name)") else {
                    throw GitHubError.invalidResponse
                }
                result.append(repository)
            }
            if batch.count < 100 { break }
            page += 1
        }
        return Array(Set(result)).sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    func branches(in repository: GitHubRepository) async throws -> [GitHubBranch] {
        let path = try repositoryPath(repository) + ["branches"]
        var result: [GitHubBranch] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let batch: [GitHubBranch] = try await send(path: path, query: [
                URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))
            ])
            result.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Resolve the base at submission time, then create a new ref without updating an existing one.
    func createBranch(name: String, base: String, in repository: GitHubRepository) async throws -> URL {
        let path = try repositoryPath(repository)
        if let message = BranchNaming.creationValidationMessage(name) { throw GitHubError.invalidBranch(message) }
        if let message = BranchNaming.validationMessage(base) { throw GitHubError.invalidBranch(message) }
        let reference: Reference = try await send(path: path + ["git", "ref", "heads", base])
        guard reference.ref == "refs/heads/\(base)", !reference.object.sha.isEmpty else { throw GitHubError.invalidResponse }
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(CreateReference(ref: "refs/heads/\(name)", sha: reference.object.sha))
        do {
            let created: Reference = try await send(path: path + ["git", "refs"], method: "POST", body: body)
            guard created.ref == "refs/heads/\(name)", created.object.sha == reference.object.sha else {
                throw GitHubError.invalidResponse
            }
        } catch GitHubError.http(422, let message) {
            if message?.localizedCaseInsensitiveContains("already exists") == true { throw GitHubError.branchExists }
            throw GitHubError.http(422, message)
        }
        return repository.branchURL(name)
    }

    private struct Reference: Decodable { let ref: String; let object: Object; struct Object: Decodable { let sha: String } }
    private struct CreateReference: Encodable { let ref: String; let sha: String }
    private struct ListedRepository: Decodable {
        let name: String
        let owner: Owner
        let archived: Bool
        let disabled: Bool
        struct Owner: Decodable { let login: String }
    }

    private func repositoryPath(_ repository: GitHubRepository) throws -> [String] {
        guard organization.contains(repository) else { throw GitHubError.invalidRepository }
        return ["repos", repository.owner, repository.name]
    }

    static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private func send<T: Decodable>(path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> T {
        var components = URLComponents(url: organization.apiURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += "/" + path.map(Self.pathSegment).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("JPlus", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
        switch http.statusCode {
        case 200..<300:
            guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw GitHubError.invalidResponse }
            return result
        case 401: throw GitHubError.unauthorized
        case 403: throw GitHubError.forbidden(message)
        case 404: throw GitHubError.notFound
        default: throw GitHubError.http(http.statusCode, message)
        }
    }

    private struct ErrorResponse: Decodable { let message: String }
}
