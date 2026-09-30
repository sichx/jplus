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

    /// An issue's sub-tasks, or an epic's child issues, in rank order.
    func childIssues(of key: String) async throws -> IssueSearchPage {
        try await search(jql: Self.childIssuesJQL(of: key), maxResults: 100)
    }

    /// The query behind `childIssues(of:)`, also used to open the full list in Jira.
    static func childIssuesJQL(of key: String) -> String {
        "parent = \(key) ORDER BY rank ASC"
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

    /// Every comment on an issue, oldest first.
    func allComments(issueKey: String) async throws -> [JiraIssue.Comment] {
        struct Page: Decodable {
            let comments: [JiraIssue.Comment]
            let startAt: Int
            let total: Int
        }
        var all: [JiraIssue.Comment] = []
        var startAt = 0
        repeat {
            let page: Page = try await get("/rest/api/3/issue/\(issueKey)/comment", query: [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "100"),
            ])
            all += page.comments
            startAt += page.comments.count
            if page.comments.isEmpty || startAt >= page.total { break }
        } while true
        return all
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

    /// Every status on the site, across all workflows.
    func statuses() async throws -> [JiraIssue.Status] {
        try await get("/rest/api/3/status")
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

    /// Every version of a project in one response, without issue counts.
    func versionsWithoutCounts(projectKey: String) async throws -> [JiraVersion] {
        try await get("/rest/api/3/project/\(projectKey)/versions")
    }

    /// Adds or removes one fix version, leaving the issue's others as they are,
    /// so concurrent changes to different versions can't undo each other.
    func setFixVersion(id versionID: String, included: Bool, onIssue key: String) async throws {
        try await put("/rest/api/3/issue/\(key)", json: [
            "update": ["fixVersions": [[included ? "add" : "remove": ["id": versionID]]]],
        ])
    }

    /// Renames an issue.
    func setSummary(_ summary: String, onIssue key: String) async throws {
        try await put("/rest/api/3/issue/\(key)", json: ["fields": ["summary": summary]])
    }

    /// Assigns an issue, or unassigns it when `accountID` is nil.
    func setAssignee(accountID: String?, onIssue key: String) async throws {
        try await put("/rest/api/3/issue/\(key)/assignee", json: ["accountId": accountID ?? NSNull()])
    }

    /// Changes an issue's reporter. Needs the Modify Reporter permission.
    func setReporter(accountID: String, onIssue key: String) async throws {
        try await put("/rest/api/3/issue/\(key)", json: ["fields": ["reporter": ["accountId": accountID]]])
    }

    /// The priorities this issue can be given, in the site's order, or nil
    /// if the issue's edit screen doesn't include Priority.
    func allowedPriorities(issueKey: String) async throws -> [JiraIssue.Priority]? {
        struct EditMeta: Decodable {
            let fields: Fields
            struct Fields: Decodable { let priority: Field? }
            struct Field: Decodable { let allowedValues: [JiraIssue.Priority]? }
        }
        let meta: EditMeta = try await get("/rest/api/3/issue/\(issueKey)/editmeta")
        return meta.fields.priority?.allowedValues
    }

    /// Changes an issue's priority.
    func setPriority(id priorityID: String, onIssue key: String) async throws {
        try await put("/rest/api/3/issue/\(key)", json: ["fields": ["priority": ["id": priorityID]]])
    }

    /// People who can be assigned the issue, matching `query` by name or email.
    func assignableUsers(issueKey: String, query: String) async throws -> [JiraUser] {
        try await get("/rest/api/3/user/assignable/search", query: [
            URLQueryItem(name: "issueKey", value: issueKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "maxResults", value: "20"),
        ])
    }

    /// Active people on the site matching `query`, leaving out apps and bots.
    func users(matching query: String) async throws -> [JiraUser] {
        let users: [JiraUser] = try await get("/rest/api/3/user/search", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "maxResults", value: "20"),
        ])
        return users.filter { ($0.accountType ?? "atlassian") == "atlassian" && $0.active != false }
    }

    /// The moves the workflow allows from the issue's current status.
    func transitions(issueKey: String) async throws -> [JiraTransition] {
        struct Response: Decodable { let transitions: [JiraTransition] }
        let response: Response = try await get("/rest/api/3/issue/\(issueKey)/transitions")
        return response.transitions
    }

    /// Moves an issue to another status.
    func transition(issueKey: String, transitionID: String) async throws {
        var request = makeRequest(path: "/rest/api/3/issue/\(issueKey)/transitions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["transition": ["id": transitionID]])
        _ = try await sendData(request)
    }

    /// The description as Jira wiki markup. API v2 converts to and from ADF on
    /// the server, keeping images, tables, links and mentions through a
    /// plain-text edit, which a local ADF conversion would lose.
    func descriptionWikiMarkup(issueKey: String) async throws -> String {
        struct Response: Decodable {
            let fields: Fields
            struct Fields: Decodable { let description: String? }
        }
        let response: Response = try await get(
            "/rest/api/2/issue/\(issueKey)",
            query: [URLQueryItem(name: "fields", value: "description")]
        )
        return response.fields.description ?? ""
    }

    /// Replaces the description with wiki markup; empty text clears it.
    func setDescription(wikiMarkup: String, onIssue key: String) async throws {
        let trimmed = wikiMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        try await put("/rest/api/2/issue/\(key)", json: [
            "fields": ["description": trimmed.isEmpty ? NSNull() : wikiMarkup as Any],
        ])
    }

    /// Adds a comment written in wiki markup.
    func addComment(wikiMarkup: String, to issueKey: String) async throws {
        struct Created: Decodable { let id: String }
        let _: Created = try await post("/rest/api/2/issue/\(issueKey)/comment", json: ["body": wikiMarkup])
    }

    /// Replies to a comment. REST can't create replies yet, so this uses the
    /// GraphQL gateway's `addComment`, which takes ADF rather than wiki
    /// markup: `text` is plain text, converted like a new ticket's description.
    /// - Parameters:
    ///   - parentID: The comment that started the thread.
    ///   - issueID: The issue's numeric id, not its key.
    func addReply(_ text: String, toComment parentID: String, issueID: String, cloudId: String) async throws {
        struct Response: Decodable {
            let data: DataField?
            let errors: [Message]?
            struct DataField: Decodable { let jira: Jira? }
            struct Jira: Decodable { let addComment: Payload? }
            struct Payload: Decodable {
                let success: Bool
                let errors: [Message]?
            }
            struct Message: Decodable { let message: String? }
        }
        let query = """
        mutation JPlusAddComment($input: JiraAddCommentInput!) {
          jira {
            addComment(input: $input) {
              success
              errors { message }
              comment { commentId }
            }
          }
        }
        """
        let response: Response = try await graphQL(
            operationName: "JPlusAddComment",
            query: query,
            variables: ["input": [
                "issueId": "ari:cloud:jira:\(cloudId):issue/\(issueID)",
                "content": ["version": 1, "jsonValue": ADFBuilder.document(from: text)],
                "threadParentId": parentID,
            ]]
        )
        guard let payload = response.data?.jira?.addComment, payload.success else {
            let messages = (response.data?.jira?.addComment?.errors ?? response.errors ?? []).compactMap(\.message)
            throw JiraError.http(status: 200, message: messages.isEmpty ? "Jira didn't accept the reply." : messages.joined(separator: " "))
        }
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

    /// Designs linked to an issue (Jira's "Designs" panel, filled by Figma for
    /// Jira) and the media file id of each attachment. Neither is in REST.
    /// A field that fails comes back empty as long as the other one loaded.
    func issueExtras(key: String, cloudId: String) async throws -> IssueExtras {
        let query = """
        query JPlusIssueExtras($cloudId: ID!, $key: String!) {
          jira {
            issueByKey(cloudId: $cloudId, key: $key) {
              designs(first: 50) @optIn(to: "GraphStoreIssueAssociatedDesign") {
                edges { node { ... on DevOpsDesign { id displayName url inspectUrl status } } }
              }
              attachments(first: 100) {
                edges { node { attachmentId mediaApiFileId } }
              }
            }
          }
        }
        """
        let response: IssueExtrasResponse = try await graphQL(
            operationName: "JPlusIssueExtras",
            query: query,
            variables: ["cloudId": cloudId, "key": key],
            // The design graph refuses queries that don't name the site.
            headers: ["X-Query-Context": "ari:cloud:platform::site/\(cloudId)"]
        )
        guard let issue = response.data?.jira?.issueByKey else {
            let message = response.errors?.map(\.message).joined(separator: " ") ?? "Empty GraphQL response."
            throw JiraError.http(status: 200, message: message)
        }

        var extras = IssueExtras()
        extras.designs = (issue.designs?.nodes ?? []).compactMap { node in
            guard let id = node.id, let url = node.url.flatMap(URL.init(string:)) else { return nil }
            let name = node.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return IssueDesign(
                id: id,
                name: name.isEmpty ? url.absoluteString : name,
                url: url,
                inspectURL: node.inspectUrl.flatMap(URL.init(string:)),
                isReadyForDev: node.status == "READY_FOR_DEVELOPMENT"
            )
        }
        for node in issue.attachments?.nodes ?? [] {
            if let mediaID = node.mediaApiFileId, let attachmentID = node.attachmentId {
                extras.attachmentIDsByMediaID[mediaID] = attachmentID
            }
        }
        return extras
    }

    /// An attachment's bytes.
    func attachmentContent(id: String) async throws -> Data {
        try await attachmentData("content", id: id, timeout: 120)
    }

    /// Jira's small preview of an image attachment (about 200 px).
    func attachmentThumbnail(id: String) async throws -> Data {
        try await attachmentData("thumbnail", id: id, timeout: 30)
    }

    /// With `redirect=false` Jira sends the bytes itself instead of redirecting
    /// to the media service with a short-lived token.
    private func attachmentData(_ kind: String, id: String, timeout: TimeInterval) async throws -> Data {
        var request = makeRequest(
            path: "/rest/api/3/attachment/\(kind)/\(id)",
            query: [URLQueryItem(name: "redirect", value: "false")],
            method: "GET"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        return try await sendData(request)
    }

    /// Web URL for an issue on this site.
    func browseURL(for issueKey: String) -> URL {
        credentials.siteURL.appending(path: "browse/\(issueKey)")
    }

    /// Web URL for an attachment. In a browser it downloads the file.
    func browseURL(for attachment: JiraIssue.Attachment) -> URL {
        credentials.siteURL.appending(path: "secure/attachment/\(attachment.id)/\(attachment.filename)")
    }

    /// Web URL for a version's release page, all issues tab.
    func browseURL(projectKey: String, versionID: String) -> URL {
        credentials.siteURL.appending(path: "projects/\(projectKey)/versions/\(versionID)/tab/release-report-all-issues")
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

    /// For edits, which answer 204 No Content.
    func put(_ path: String, json: [String: Any]) async throws {
        var request = makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        _ = try await sendData(request)
    }

    /// Atlassian's GraphQL gateway on the site domain accepts the same Basic auth.
    func graphQL<T: Decodable>(operationName: String, query: String, variables: [String: Any], experimentalAPIs: [String] = [], headers: [String: String] = [:]) async throws -> T {
        var request = makeRequest(path: "/gateway/api/graphql", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !experimentalAPIs.isEmpty {
            request.setValue(experimentalAPIs.joined(separator: ", "), forHTTPHeaderField: "X-ExperimentalApi")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
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
        let data = try await sendData(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw JiraError.decoding(error)
        }
    }

    private func sendData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JiraError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }

        switch http.statusCode {
        case 200..<300: return data
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
