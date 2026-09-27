import Foundation

enum JiraError: LocalizedError {
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case http(status: Int, message: String?)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Jira returned an unexpected response."
        case .unauthorized:
            return "Jira rejected the credentials. Check the email and API token."
        case .forbidden:
            return "This account doesn't have permission to access that resource."
        case .notFound:
            return "Not found. Check the site address."
        case .http(let status, let message):
            return message.map { "Jira error \(status): \($0)" } ?? "Jira error \(status)."
        case .decoding:
            return "Couldn't read Jira's response."
        case .network(let error):
            return error.localizedDescription
        }
    }
}

/// Thin, stateless REST client for Jira Cloud (`/rest/api/3`).
/// One instance per signed-in account; construct a new one on sign-in.
struct JiraClient: Sendable {
    let credentials: JiraCredentials
    private let session: URLSession
    private let decoder: JSONDecoder

    init(credentials: JiraCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = JiraDateParser.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(raw)")
            }
            return date
        }
        self.decoder = decoder
    }

    // MARK: - Endpoints

    /// Validates credentials and returns the current user.
    func myself() async throws -> JiraUser {
        try await get("/rest/api/3/myself")
    }

    /// Fetches one issue by key, e.g. "VPE-5555".
    func issue(key: String) async throws -> JiraIssue {
        try await get(
            "/rest/api/3/issue/\(key)",
            query: [URLQueryItem(name: "fields", value: JiraIssue.requestedFields.joined(separator: ","))]
        )
    }

    /// Runs a JQL query. Pass the previous page's `nextPageToken` to continue.
    func search(jql: String, maxResults: Int = 50, nextPageToken: String? = nil) async throws -> IssueSearchPage {
        var query = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: IssueSummary.requestedFields.joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        if let nextPageToken {
            query.append(URLQueryItem(name: "nextPageToken", value: nextPageToken))
        }
        return try await get("/rest/api/3/search/jql", query: query)
    }

    /// Runs a JQL query returning the given fields, decoded as `Issue`.
    func search<Issue: Decodable>(jql: String, fields: [String], maxResults: Int = 50, nextPageToken: String? = nil) async throws -> SearchPage<Issue> {
        var query = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        if let nextPageToken {
            query.append(URLQueryItem(name: "nextPageToken", value: nextPageToken))
        }
        return try await get("/rest/api/3/search/jql", query: query)
    }

    /// Jira's fast estimate of how many issues match.
    func approximateCount(jql: String) async throws -> Int {
        struct Count: Decodable { let count: Int }
        let result: Count = try await post("/rest/api/3/search/approximate-count", json: ["jql": jql])
        return result.count
    }

    /// Creation date of the oldest visible issue.
    func earliestCreated() async throws -> Date? {
        struct Created: Decodable, Sendable {
            let fields: Fields
            struct Fields: Decodable, Sendable { let created: Date }
        }
        let page: SearchPage<Created> = try await search(jql: "created is not EMPTY ORDER BY created ASC", fields: ["created"], maxResults: 1)
        return page.issues.first?.fields.created
    }

    /// All projects visible to the user, ordered by name.
    func projects() async throws -> [JiraProject] {
        var all: [JiraProject] = []
        var startAt = 0
        while all.count < 2000 {
            let page: ProjectPage = try await get("/rest/api/3/project/search", query: [
                URLQueryItem(name: "orderBy", value: "name"),
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "100"),
            ])
            all += page.values
            startAt += page.values.count
            if page.isLast || page.values.isEmpty { break }
        }
        return all
    }

    /// All versions of a project, newest first, with per-status issue counts.
    func versions(projectKey: String) async throws -> [JiraVersion] {
        var all: [JiraVersion] = []
        var startAt = 0
        while all.count < 2000 {
            let page: VersionPage = try await get("/rest/api/3/project/\(projectKey)/version", query: [
                URLQueryItem(name: "orderBy", value: "-sequence"),
                URLQueryItem(name: "expand", value: "issuesstatus"),
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "50"),
            ])
            all += page.values
            startAt += page.values.count
            if page.isLast || page.values.isEmpty { break }
        }
        return all
    }

    /// Project metadata including the issue types available for creation.
    func projectDetail(key: String) async throws -> JiraProjectDetail {
        try await get("/rest/api/3/project/\(key)")
    }

    /// Creates an issue. `description` is plain text, converted to ADF.
    func createIssue(projectKey: String, issueTypeId: String, summary: String, description: String) async throws -> CreatedIssue {
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "issuetype": ["id": issueTypeId],
            "summary": summary,
        ]
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            fields["description"] = ADFBuilder.document(from: trimmed)
        }
        return try await post("/rest/api/3/issue", json: ["fields": fields])
    }

    /// Uploads one attachment to an issue.
    @discardableResult
    func attach(_ data: Data, filename: String, mimeType: String, to issueKey: String) async throws -> [JiraAttachment] {
        let boundary = "JPlus-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")

        var request = makeRequest(path: "/rest/api/3/issue/\(issueKey)/attachments", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.httpBody = body
        request.timeoutInterval = 120
        return try await send(request)
    }

    /// The site's cloud id, needed to build ARIs for the GraphQL gateway.
    func cloudId() async throws -> String {
        struct TenantInfo: Decodable { let cloudId: String }
        let info: TenantInfo = try await get("/_edge/tenant_info")
        return info.cloudId
    }

    /// "Version highlights" for a project's versions, keyed by version id.
    /// Covers unreleased, released and archived versions, paging through all.
    /// Pass `search` (a version name) to fetch just the matching versions.
    func versionHighlights(projectId: String, cloudId: String, search: String? = nil) async throws -> [String: VersionHighlights] {
        let query = """
        query JPlusVersionHighlights($projectId: ID!, $filter: [JiraVersionStatus], $search: String, $after: String) {
          jira {
            versionsForProject(jiraProjectId: $projectId, filter: $filter, searchString: $search, first: 50, after: $after) {
              pageInfo { hasNextPage endCursor }
              edges { node {
                versionId name description
                richTextSection @optIn(to: "JiraVersionRichTextSection") { title content { json } }
              } }
            }
          }
        }
        """
        var baseVariables: [String: Any] = [
            "projectId": "ari:cloud:jira:\(cloudId):project/\(projectId)",
            "filter": ["UNRELEASED", "RELEASED", "ARCHIVED"],
        ]
        if let search, !search.isEmpty { baseVariables["search"] = search }

        var result: [String: VersionHighlights] = [:]
        var after: String?
        var pages = 0
        repeat {
            var variables = baseVariables
            if let after { variables["after"] = after }
            let page: VersionHighlightsPage = try await graphQL(
                operationName: "JPlusVersionHighlights",
                query: query,
                variables: variables,
                experimentalAPIs: ["VersionsForProject"]
            )
            if let errors = page.errors, !errors.isEmpty, page.data == nil {
                throw JiraError.http(status: 200, message: errors.map(\.message).joined(separator: " "))
            }
            guard let connection = page.data?.jira.versionsForProject else {
                let message = page.errors?.map(\.message).joined(separator: " ") ?? "Empty GraphQL response."
                throw JiraError.http(status: 200, message: message)
            }
            for edge in connection.edges {
                let node = edge.node
                result[node.versionId] = VersionHighlights(
                    versionId: node.versionId,
                    title: node.richTextSection?.title,
                    content: node.richTextSection?.content?.json,
                    description: node.description.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            after = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : nil
            pages += 1
        } while after != nil && pages < 40
        return result
    }

    /// Web URL for an issue on this site.
    func browseURL(for issueKey: String) -> URL {
        credentials.siteURL.appending(path: "browse/\(issueKey)")
    }

    /// Web URL for a JQL query on this site.
    func browseURL(jql: String) -> URL {
        var components = URLComponents(url: credentials.siteURL, resolvingAgainstBaseURL: false)!
        components.path = "/issues/"
        components.percentEncodedQuery = Self.encodeQuery([URLQueryItem(name: "jql", value: jql)])
        return components.url!
    }

    // MARK: - Transport

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(makeRequest(path: path, query: query, method: "GET"))
    }

    func post<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    /// Atlassian's GraphQL gateway on the site domain accepts the same Basic auth.
    func graphQL<T: Decodable>(operationName: String, query: String, variables: [String: Any], experimentalAPIs: [String] = []) async throws -> T {
        var request = makeRequest(path: "/gateway/api/graphql", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !experimentalAPIs.isEmpty {
            request.setValue(experimentalAPIs.joined(separator: ", "), forHTTPHeaderField: "X-ExperimentalApi")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": operationName,
            "query": query,
            "variables": variables,
        ])
        return try await send(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = [], method: String) -> URLRequest {
        var components = URLComponents(url: credentials.siteURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = query.isEmpty ? nil : Self.encodeQuery(query)

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JiraError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }

        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw JiraError.decoding(error)
            }
        case 401: throw JiraError.unauthorized
        case 403: throw JiraError.forbidden
        case 404: throw JiraError.notFound
        default:  throw JiraError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside the unreserved set, so `+`, `&`, `=`
    /// and spaces inside JQL survive the round trip.
    static func encodeQuery(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? item.name
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
            return "\(name)=\(value)"
        }.joined(separator: "&")
    }

    /// Jira error bodies are usually `{"errorMessages":[…],"errors":{…}}`.
    private static func errorMessage(from data: Data) -> String? {
        struct Body: Decodable {
            let errorMessages: [String]?
            let errors: [String: String]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        let fieldErrors = (body.errors ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        let messages = (body.errorMessages ?? []) + fieldErrors
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

/// Jira emits timestamps like `2025-09-24T10:11:12.345-0700`, which the
/// ISO 8601 parsers reject because of the colon-less offset.
nonisolated enum JiraDateParser {
    nonisolated(unsafe) private static let jiraFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = jiraFormatter.date(from: raw) { return date }
        if let date = try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: .iso8601)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
