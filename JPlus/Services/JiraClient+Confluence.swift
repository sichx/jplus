import Foundation

/// Confluence Cloud's v2 API lives on the same site under `/wiki/api/v2`
/// and takes the same email + API token, so the Jira client serves it too.
extension JiraClient {
    func confluenceFolder(id: String) async throws -> ConfluenceFolder {
        try await get("/wiki/api/v2/folders/\(id)")
    }

    /// Pages and folders directly inside a folder. Confluence pages these at
    /// 250; a priorities folder holds months and a month holds days, so one
    /// page is enough.
    func confluenceFolderChildren(id: String) async throws -> [ConfluenceChild] {
        struct Page: Decodable { let results: [ConfluenceChild] }
        let page: Page = try await get("/wiki/api/v2/folders/\(id)/direct-children", query: [
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// Site-wide content search; `cql` like `type = folder and title = "Daily Priorities"`.
    func confluenceSearch(cql: String, limit: Int = 25) async throws -> [ConfluenceSearchResult] {
        struct Page: Decodable { let results: [ConfluenceSearchResult] }
        let page: Page = try await get("/wiki/rest/api/search", query: [
            URLQueryItem(name: "cql", value: cql),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return page.results
    }

    func confluencePage(id: String) async throws -> ConfluencePage {
        try await get("/wiki/api/v2/pages/\(id)", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
        ])
    }

    /// Many pages with their bodies, as search needs every day's: a request
    /// per hundred ids (more if Confluence splits its answer), where reading
    /// them one at a time took a request each. Pages that have gone, or been
    /// archived, are left out.
    func confluencePages(ids: [String]) async throws -> [ConfluencePage] {
        struct Page: Decodable {
            let results: [ConfluencePage]
            let _links: Links?
            struct Links: Decodable { let next: String? }
        }
        var pages: [ConfluencePage] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            var cursor: String?
            repeat {
                var query = batch.map { URLQueryItem(name: "id", value: $0) }
                query += [
                    URLQueryItem(name: "body-format", value: "atlas_doc_format"),
                    URLQueryItem(name: "status", value: "current"),
                    URLQueryItem(name: "limit", value: "250"),
                ]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let page: Page = try await get("/wiki/api/v2/pages", query: query)
                pages += page.results
                // The next part's link carries a cursor to ask for it with.
                cursor = page.results.isEmpty ? nil : page._links?.next
                    .flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "cursor" }?.value }
            } while cursor != nil
        }
        return pages
    }

    /// A page's open inline comments (the ones on highlighted text), oldest
    /// first. Replies aren't among them; `confluenceCommentReplies` has those.
    func confluenceInlineComments(pageID: String) async throws -> [ConfluenceComment] {
        struct Page: Decodable { let results: [ConfluenceComment] }
        let page: Page = try await get("/wiki/api/v2/pages/\(pageID)/inline-comments", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
            URLQueryItem(name: "resolution-status", value: "open"),
            URLQueryItem(name: "resolution-status", value: "reopened"),
            URLQueryItem(name: "sort", value: "created-date"),
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// The replies to an inline comment, oldest first.
    func confluenceCommentReplies(commentID: String) async throws -> [ConfluenceComment] {
        struct Page: Decodable { let results: [ConfluenceComment] }
        let page: Page = try await get("/wiki/api/v2/inline-comments/\(commentID)/children", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
            URLQueryItem(name: "sort", value: "created-date"),
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// Adds a reply to the thread an inline comment starts. A reply hangs on
    /// its parent, so it names no page and highlights no text of its own.
    @discardableResult
    func replyToConfluenceComment(_ commentID: String, document: ADFNode) async throws -> ConfluenceComment {
        try await post("/wiki/api/v2/inline-comments", json: [
            "parentCommentId": commentID,
            "body": try Self.confluenceBody(document),
        ])
    }

    /// Starts an inline comment thread, highlighting text on the page:
    /// the `matchIndex`th (from 0) of the page's `matchCount` copies of
    /// `selection`. Confluence adds the highlight to the page's body.
    @discardableResult
    func createConfluenceInlineComment(pageID: String, document: ADFNode, selection: String, matchIndex: Int, matchCount: Int) async throws -> ConfluenceComment {
        try await post("/wiki/api/v2/inline-comments", json: [
            "pageId": pageID,
            "body": try Self.confluenceBody(document),
            "inlineCommentProperties": [
                "textSelection": selection,
                "textSelectionMatchCount": matchCount,
                "textSelectionMatchIndex": matchIndex,
            ],
        ])
    }

    /// The files attached to a page. A day's photos are a handful, so one
    /// page of 250 holds them.
    func confluenceAttachments(pageID: String) async throws -> [ConfluenceAttachment] {
        struct Page: Decodable { let results: [ConfluenceAttachment] }
        let page: Page = try await get("/wiki/api/v2/pages/\(pageID)/attachments", query: [
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    func confluenceAttachment(id: String) async throws -> ConfluenceAttachment {
        try await get("/wiki/api/v2/attachments/\(id)")
    }

    /// Attaches a file to a page, as a minor edit so watchers aren't told.
    /// The v2 API can't upload, so this is v1's, which refuses a file name
    /// the page already has (a new version of it would be a PUT). The page
    /// body is left alone; showing the file there is up to the caller.
    func attachToConfluencePage(_ data: Data, filename: String, mimeType: String, pageID: String) async throws -> ConfluenceAttachment {
        struct Uploaded: Decodable {
            let results: [Result]
            struct Result: Decodable {
                let id: String
                let title: String
                let extensions: Extensions?
                let _links: Links?
            }
            struct Extensions: Decodable {
                let mediaType: String?
                let fileSize: Int?
                let fileId: String?
            }
            struct Links: Decodable { let download: String? }
        }
        let uploaded: Uploaded = try await upload(data, filename: filename, mimeType: mimeType,
                                                  to: "/wiki/rest/api/content/\(pageID)/child/attachment",
                                                  xsrfToken: "nocheck", fields: ["minorEdit": "true"])
        guard let result = uploaded.results.first else { throw JiraError.invalidResponse }
        // The media file id is what the page body points at. When v1 doesn't
        // say it, v2 does.
        if let fileID = result.extensions?.fileId {
            return ConfluenceAttachment(id: result.id, title: result.title, mediaType: result.extensions?.mediaType ?? mimeType,
                                        fileId: fileID, fileSize: result.extensions?.fileSize ?? data.count,
                                        downloadLink: result._links?.download, pageId: pageID)
        }
        return try await confluenceAttachment(id: result.id)
    }

    func createConfluenceFolder(title: String, spaceID: String, parentID: String) async throws -> ConfluenceFolder {
        try await post("/wiki/api/v2/folders", json: [
            "spaceId": spaceID,
            "title": title,
            "parentId": parentID,
        ])
    }

    func createConfluencePage(title: String, spaceID: String, parentID: String, document: ADFNode) async throws -> ConfluencePage {
        try await post("/wiki/api/v2/pages", json: [
            "spaceId": spaceID,
            "status": "current",
            "title": title,
            "parentId": parentID,
            "body": try Self.confluenceBody(document),
        ])
    }

    /// Replaces a page's body. Confluence answers 409 when `version` is no
    /// longer the current one, i.e. someone else saved first.
    func updateConfluencePage(id: String, title: String, version: Int, document: ADFNode, message: String = "") async throws -> ConfluencePage {
        try await put("/wiki/api/v2/pages/\(id)", json: [
            "id": id,
            "status": "current",
            "title": title,
            "body": try Self.confluenceBody(document),
            "version": ["number": version, "message": message],
        ])
    }

    func deleteConfluencePage(id: String) async throws {
        try await delete("/wiki/api/v2/pages/\(id)")
    }

    /// Asks Confluence to archive a page: it leaves its folder for the
    /// space's archive, where it can be restored. That happens in the
    /// background; follow it with `confluenceLongTask` and the returned id.
    /// Takes the space's Archive permission, which can come without Delete.
    func archiveConfluencePage(id: String) async throws -> String {
        struct Accepted: Decodable { let id: String }
        let accepted: Accepted = try await post("/wiki/rest/api/content/archive", json: [
            "pages": [["id": Int(id).map { $0 as Any } ?? id]],
        ])
        return accepted.id
    }

    /// A background job Confluence is running, such as an archive.
    func confluenceLongTask(id: String) async throws -> ConfluenceLongTask {
        try await get("/wiki/rest/api/longtask/\(id)")
    }

    /// Pages and comments take ADF as a JSON string, with the schema version at the root.
    private static func confluenceBody(_ document: ADFNode) throws -> [String: Any] {
        let data = try JSONEncoder().encode(document)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.invalidResponse
        }
        object["version"] = 1
        let value = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return ["representation": "atlas_doc_format", "value": String(decoding: value, as: UTF8.self)]
    }
}

extension JiraError {
    /// Confluence's answer to saving over a newer page version.
    var isConflict: Bool {
        if case .http(let status, _) = self { return status == 409 }
        return false
    }
}
