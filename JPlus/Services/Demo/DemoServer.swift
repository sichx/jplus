import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A local stand-in for a Jira Cloud site, answering the REST, Confluence and
/// GraphQL requests `JiraClient` makes with the sample data in `DemoData`.
/// Edits (status changes, comments, new tickets, priorities) are kept in
/// memory for as long as the app runs.
nonisolated final class DemoServer: @unchecked Sendable {
    static let shared = DemoServer()

    struct Response {
        var status = 200
        var data = Data()
        var contentType = "application/json"
    }

    private let lock = NSLock()
    private var state = DemoData.make(now: Date())
    private var images: [String: Data] = [:]
    private var me: String { DemoData.reviewer.id }

    func respond(to request: URLRequest, body: Data) -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return error(400, "Bad request.")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let parts = components.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let method = request.httpMethod ?? "GET"
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return route(method: method, parts: parts, query: query, json: json, body: body,
                     contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    // MARK: - Routing

    private func route(method: String, parts: [String], query: [String: String], json: [String: Any], body: Data, contentType: String) -> Response {
        if match(method, parts, "GET _edge/tenant_info") != nil {
            return ok(["cloudId": "demo-cloud"])
        }
        if match(method, parts, "POST gateway/api/graphql") != nil {
            return graphQL(json)
        }

        // Jira: people, fields, projects
        if match(method, parts, "GET rest/api/3/myself") != nil {
            return ok(userJSON(me))
        }
        if match(method, parts, "GET rest/api/3/status") != nil {
            return ok(state.statuses.map(statusJSON))
        }
        if match(method, parts, "GET rest/api/3/field") != nil {
            return ok([
                ["id": "summary", "name": "Summary", "schema": ["type": "string"]],
                ["id": DemoData.teamFieldID, "name": "Team",
                 "schema": ["type": "team", "custom": "com.atlassian.jira.plugin.system.customfieldtypes:atlassian-team"]],
            ])
        }
        if match(method, parts, "GET rest/api/3/user/bulk") != nil {
            // The query keeps only the last accountId, so this answers with everyone.
            let values = state.users.map { userJSON($0.id) }
            return ok(["values": values, "isLast": true, "total": values.count, "startAt": 0, "maxResults": values.count])
        }
        if match(method, parts, "GET rest/api/3/user/search") != nil || match(method, parts, "GET rest/api/3/user/assignable/search") != nil {
            let text = (query["query"] ?? "").lowercased()
            let users = state.users.filter { text.isEmpty || $0.name.lowercased().contains(text) || $0.email.lowercased().contains(text) }
            return ok(users.map { userJSON($0.id) })
        }
        if match(method, parts, "GET rest/api/3/project/search") != nil {
            let values = state.projects.sorted { $0.name < $1.name }.map(projectJSON)
            return ok(["values": values, "isLast": true, "total": values.count, "startAt": 0, "maxResults": 100])
        }
        if let p = match(method, parts, "GET rest/api/3/project/*") {
            let key = p[0]
            guard let project = project(key) else { return error(404, "No project could be found with key '\(key)'.") }
            var detail = projectJSON(project)
            detail["issueTypes"] = state.issueTypes.map(issueTypeJSON)
            return ok(detail)
        }
        if let p = match(method, parts, "GET rest/api/3/project/*/version") {
            let key = p[0]
            let values = versions(of: key).map { versionJSON($0, counts: true) }
            return ok(["values": values, "isLast": true, "total": values.count, "startAt": 0, "maxResults": 50])
        }
        if let p = match(method, parts, "GET rest/api/3/project/*/versions") {
            let key = p[0]
            return ok(versions(of: key).map { versionJSON($0, counts: false) })
        }
        if match(method, parts, "GET rest/api/3/issue/createmeta/*/issuetypes/*") != nil {
            let fields = ["summary", "description", "issuetype", "project", "priority", "assignee", "fixVersions", DemoData.teamFieldID]
            return ok(["fields": fields.map { ["fieldId": $0] }, "total": fields.count, "startAt": 0, "maxResults": 200])
        }

        // Jira: search
        if match(method, parts, "GET rest/api/3/search/jql") != nil {
            return search(query)
        }
        if match(method, parts, "POST rest/api/3/search/approximate-count") != nil {
            let jql = DemoJQL(json["jql"] as? String ?? "")
            return ok(["count": state.issues.filter { jql.matches($0, in: state, currentUser: me) }.count])
        }

        // Jira: one issue
        if match(method, parts, "POST rest/api/3/issue") != nil {
            return createIssue(json)
        }
        if let p = match(method, parts, "GET rest/api/3/issue/*") {
            let key = p[0]
            guard let issue = issue(key) else { return notFound(key) }
            return ok(issueJSON(issue, fields: Self.fieldList(query["fields"])))
        }
        if let p = match(method, parts, "PUT rest/api/3/issue/*") {
            let key = p[0]
            return edit(key) { issue in self.applyEdit(json, to: &issue) }
        }
        if let p = match(method, parts, "PUT rest/api/3/issue/*/assignee") {
            let key = p[0]
            return edit(key) { $0.assignee = json["accountId"] as? String }
        }
        if let p = match(method, parts, "GET rest/api/3/issue/*/editmeta") {
            let key = p[0]
            guard self.issue(key) != nil else { return notFound(key) }
            return ok(["fields": ["priority": ["allowedValues": state.priorities.enumerated().map { ["id": String($0.offset + 1), "name": $0.element] }]]])
        }
        if let p = match(method, parts, "GET rest/api/3/issue/*/transitions") {
            let key = p[0]
            guard let issue = issue(key) else { return notFound(key) }
            let transitions = state.statuses.filter { $0.name != issue.status }.map { status in
                ["id": status.id, "name": status.name, "to": statusJSON(status)] as [String: Any]
            }
            return ok(["transitions": transitions])
        }
        if let p = match(method, parts, "POST rest/api/3/issue/*/transitions") {
            let key = p[0]
            let id = (json["transition"] as? [String: Any])?["id"] as? String
            guard let status = state.statuses.first(where: { $0.id == id }) else { return error(400, "Transition not found.") }
            return edit(key) { $0.status = status.name }
        }
        if let p = match(method, parts, "GET rest/api/3/issue/*/comment") {
            let key = p[0]
            guard let issue = issue(key) else { return notFound(key) }
            let comments = issue.comments.map { commentJSON($0, withParent: true) }
            return ok(["comments": comments, "startAt": 0, "maxResults": 100, "total": comments.count])
        }
        if let p = match(method, parts, "POST rest/api/3/issue/*/attachments") {
            let key = p[0]
            return attach(body, contentType: contentType, to: key)
        }

        // Jira API v2: wiki markup for editing descriptions and comments
        if let p = match(method, parts, "GET rest/api/2/issue/*") {
            let key = p[0]
            guard let issue = issue(key) else { return notFound(key) }
            return ok(["key": issue.key, "fields": ["description": ADF.plainText(issue.description)]])
        }
        if let p = match(method, parts, "PUT rest/api/2/issue/*") {
            let key = p[0]
            let text = (json["fields"] as? [String: Any])?["description"] as? String
            return edit(key) { $0.description = text.map(Self.document(fromWiki:)) }
        }
        if let p = match(method, parts, "POST rest/api/2/issue/*/comment") {
            let key = p[0]
            let text = json["body"] as? String ?? ""
            // Taken before the edit, which holds the issue list while it runs.
            let id = newID()
            let me = self.me
            let result = edit(key) { issue in
                issue.comments.append(DemoComment(id: id, author: me, body: Self.document(fromWiki: text), created: Date(), parentID: nil))
            }
            return result.status == 204 ? ok(["id": id], status: 201) : result
        }

        // Attachments
        if let p = match(method, parts, "GET rest/api/3/attachment/*/*") {
            let kind = p[0]
            let id = p[1]
            return attachmentData(id: id, thumbnail: kind == "thumbnail")
        }

        // Confluence
        if match(method, parts, "GET wiki/rest/api/search") != nil {
            return confluenceSearch(query["cql"] ?? "")
        }
        if let p = match(method, parts, "GET wiki/api/v2/folders/*") {
            let id = p[0]
            guard let folder = state.folders.first(where: { $0.id == id }) else { return error(404, "Folder not found.") }
            return ok(folderJSON(folder))
        }
        if let p = match(method, parts, "GET wiki/api/v2/folders/*/direct-children") {
            let id = p[0]
            let folders = state.folders.filter { $0.parentID == id }.map { ["id": $0.id, "title": $0.title, "type": "folder", "status": "current"] }
            let pages = state.pages.filter { $0.parentID == id && $0.status == "current" }.map { ["id": $0.id, "title": $0.title, "type": "page", "status": "current"] }
            return ok(["results": folders + pages])
        }
        if match(method, parts, "POST wiki/api/v2/folders") != nil {
            let folder = DemoFolder(id: newID(), title: json["title"] as? String ?? "Untitled", parentID: json["parentId"] as? String)
            state.folders.append(folder)
            return ok(folderJSON(folder))
        }
        if let p = match(method, parts, "GET wiki/api/v2/pages/*") {
            let id = p[0]
            guard let page = state.pages.first(where: { $0.id == id }) else { return error(404, "Page not found.") }
            return ok(pageJSON(page))
        }
        if let p = match(method, parts, "GET wiki/api/v2/pages/*/inline-comments") {
            let id = p[0]
            let comments = state.pageComments.filter { $0.pageID == id && $0.parentID == nil }.map(pageCommentJSON)
            return ok(["results": comments, "_links": ["base": "\(DemoSite.siteURL)/wiki"]])
        }
        if let p = match(method, parts, "GET wiki/api/v2/inline-comments/*/children") {
            let id = p[0]
            return ok(["results": state.pageComments.filter { $0.parentID == id }.map(pageCommentJSON)])
        }
        if match(method, parts, "POST wiki/api/v2/inline-comments") != nil {
            let value = (json["body"] as? [String: Any])?["value"] as? String ?? ""
            let body = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? ADF.doc([])
            if let parentID = json["parentCommentId"] as? String {
                guard let parent = state.pageComments.first(where: { $0.id == parentID }) else {
                    return error(404, "Parent comment not found.")
                }
                let reply = DemoPageComment(id: newID(), pageID: parent.pageID, author: me, body: body, created: Date(),
                                            markerRef: nil, parentID: parentID)
                state.pageComments.append(reply)
                return ok(pageCommentJSON(reply), status: 201)
            }
            // A new thread highlights the chosen copy of the selected text, as Confluence does.
            guard let pageID = json["pageId"] as? String,
                  let index = state.pages.firstIndex(where: { $0.id == pageID }),
                  let selection = json["inlineCommentProperties"] as? [String: Any],
                  let text = selection["textSelection"] as? String, !text.isEmpty,
                  let matchCount = selection["textSelectionMatchCount"] as? Int,
                  let matchIndex = selection["textSelectionMatchIndex"] as? Int,
                  let page = (try? JSONSerialization.jsonObject(with: Data(state.pages[index].body.utf8))) as? ADF.Node
            else { return error(400, "A page and the text to highlight, or a parent comment, are required.") }
            let marker = UUID().uuidString.lowercased()
            var seen = 0
            let highlighted = highlighting(text, at: matchIndex, marker: marker, in: page, seen: &seen)
            guard seen == matchCount, matchIndex < matchCount, let document = highlighted.first,
                  let data = try? JSONSerialization.data(withJSONObject: document, options: [.withoutEscapingSlashes]) else {
                return error(400, "The selected text appears \(seen) times on the page, not \(matchCount).")
            }
            state.pages[index].body = String(decoding: data, as: UTF8.self)
            state.pages[index].version += 1
            let comment = DemoPageComment(id: newID(), pageID: pageID, author: me, body: body, created: Date(),
                                          markerRef: marker, parentID: nil)
            state.pageComments.append(comment)
            return ok(pageCommentJSON(comment), status: 201)
        }
        if match(method, parts, "POST wiki/api/v2/pages") != nil {
            let body = (json["body"] as? [String: Any])?["value"] as? String ?? "{\"type\":\"doc\",\"version\":1,\"content\":[]}"
            let page = DemoPage(id: newID(), title: json["title"] as? String ?? "Untitled", parentID: json["parentId"] as? String ?? "901",
                                version: 1, body: body)
            state.pages.append(page)
            return ok(pageJSON(page))
        }
        if let p = match(method, parts, "PUT wiki/api/v2/pages/*") {
            let id = p[0]
            guard let index = state.pages.firstIndex(where: { $0.id == id }) else { return error(404, "Page not found.") }
            let version = (json["version"] as? [String: Any])?["number"] as? Int ?? 0
            guard version == state.pages[index].version + 1 else {
                return error(409, "Version must be incremented on update. Current version is: \(state.pages[index].version)")
            }
            state.pages[index].version = version
            if let title = json["title"] as? String { state.pages[index].title = title }
            if let value = (json["body"] as? [String: Any])?["value"] as? String { state.pages[index].body = value }
            return ok(pageJSON(state.pages[index]))
        }
        if match(method, parts, "POST wiki/rest/api/content/archive") != nil {
            // Archived at once; the job it reports has always finished.
            let ids = ((json["pages"] as? [[String: Any]]) ?? []).compactMap { ($0["id"] as? Int).map(String.init) ?? $0["id"] as? String }
            let indices = ids.compactMap { id in state.pages.firstIndex { $0.id == id && $0.status == "current" } }
            guard !ids.isEmpty, indices.count == ids.count else { return error(400, "Each page must exist and not be archived already.") }
            for index in indices { state.pages[index].status = "archived" }
            let task = newID()
            return ok(["id": task, "links": ["status": "/rest/api/longtask/\(task)"]], status: 202)
        }
        if let p = match(method, parts, "GET wiki/rest/api/longtask/*") {
            return ok(["id": p[0], "finished": true, "successful": true, "percentageComplete": 100, "status": "FINISH_SUCCESS",
                       "messages": [], "errors": []])
        }
        if let p = match(method, parts, "DELETE wiki/api/v2/pages/*") {
            let id = p[0]
            state.pages.removeAll { $0.id == id }
            return Response(status: 204)
        }
        return error(404, "Not available in the demo.")
    }

    /// The `*` segments of `pattern` ("GET rest/api/3/issue/*") when the
    /// request matches it, else nil.
    private func match(_ method: String, _ parts: [String], _ pattern: String) -> [String]? {
        let pieces = pattern.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0] == method else { return nil }
        let segments = pieces[1].split(separator: "/").map(String.init)
        guard segments.count == parts.count else { return nil }
        var captured: [String] = []
        for (segment, part) in zip(segments, parts) {
            if segment == "*" { captured.append(part) } else if segment != part { return nil }
        }
        return captured
    }

    // MARK: - Search

    private func search(_ query: [String: String]) -> Response {
        let jql = DemoJQL(query["jql"] ?? "")
        let matched = jql.sorted(state.issues.filter { jql.matches($0, in: state, currentUser: me) }, in: state)
        let start = Int(query["nextPageToken"] ?? "") ?? 0
        let size = max(1, min(Int(query["maxResults"] ?? "") ?? 50, 100))
        let page = Array(matched.dropFirst(start).prefix(size))
        let end = start + page.count
        let fields = Self.fieldList(query["fields"])
        var result: [String: Any] = ["issues": page.map { issueJSON($0, fields: fields) }, "isLast": end >= matched.count]
        if end < matched.count { result["nextPageToken"] = String(end) }
        return ok(result)
    }

    // MARK: - Edits

    private func edit(_ key: String, _ change: (inout DemoIssue) -> Void) -> Response {
        guard let index = state.issues.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { return notFound(key) }
        // On a copy, so `change` can read the rest of the state.
        var issue = state.issues[index]
        change(&issue)
        issue.updated = Date()
        state.issues[index] = issue
        return Response(status: 204)
    }

    private func applyEdit(_ json: [String: Any], to issue: inout DemoIssue) {
        if let fields = json["fields"] as? [String: Any] {
            if let summary = fields["summary"] as? String { issue.summary = summary }
            if let reporter = (fields["reporter"] as? [String: Any])?["accountId"] as? String { issue.reporter = reporter }
            if let id = (fields["priority"] as? [String: Any])?["id"] as? String, let index = Int(id), state.priorities.indices.contains(index - 1) {
                issue.priority = state.priorities[index - 1]
            }
            if fields.keys.contains(DemoData.teamFieldID) {
                issue.team = fields[DemoData.teamFieldID] as? String
            }
        }
        if let changes = (json["update"] as? [String: Any])?["fixVersions"] as? [[String: Any]] {
            for change in changes {
                if let id = (change["add"] as? [String: Any])?["id"] as? String, !issue.fixVersions.contains(id) {
                    issue.fixVersions.append(id)
                }
                if let id = (change["remove"] as? [String: Any])?["id"] as? String {
                    issue.fixVersions.removeAll { $0 == id }
                }
            }
        }
    }

    private func createIssue(_ json: [String: Any]) -> Response {
        let fields = json["fields"] as? [String: Any] ?? [:]
        let projectKey = ((fields["project"] as? [String: Any])?["key"] as? String ?? "APP").uppercased()
        guard project(projectKey) != nil else { return error(400, "Specify a valid project.") }
        let typeID = (fields["issuetype"] as? [String: Any])?["id"] as? String
        let type = state.issueTypes.first { $0.id == typeID }?.name ?? "Task"
        let number = (state.issues.filter { $0.projectKey == projectKey }.map(\.number).max() ?? 0) + 1
        let id = Int(newID()) ?? state.nextID
        var issue = DemoIssue(id: id, key: "\(projectKey)-\(number)", type: type,
                              summary: fields["summary"] as? String ?? "Untitled", description: fields["description"] as? [String: Any],
                              status: "To Do", priority: "Medium", assignee: nil, reporter: me, created: Date(), updated: Date())
        issue.fixVersions = ((fields["fixVersions"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        issue.team = fields[DemoData.teamFieldID] as? String
        issue.watchers = [me]
        issue.rank = state.issues.count
        state.issues.append(issue)
        return ok(["id": String(issue.id), "key": issue.key, "self": "\(DemoSite.siteURL)/rest/api/3/issue/\(issue.id)"], status: 201)
    }

    private func attach(_ body: Data, contentType: String, to key: String) -> Response {
        guard let boundary = contentType.components(separatedBy: "boundary=").last, !boundary.isEmpty,
              let headerEnd = body.range(of: Data("\r\n\r\n".utf8)) else { return error(400, "Bad upload.") }
        let header = String(decoding: body[..<headerEnd.lowerBound], as: UTF8.self)
        let filename = header.firstMatch(of: /filename="([^"]*)"/).map { String($0.1) } ?? "file"
        let mimeType = header.firstMatch(of: /Content-Type: ([^\r\n]+)/).map { String($0.1) } ?? "application/octet-stream"
        let closing = Data("\r\n--\(boundary)".utf8)
        let end = body.range(of: closing, in: headerEnd.upperBound..<body.endIndex)?.lowerBound ?? body.endIndex
        let data = body[headerEnd.upperBound..<end]
        let attachment = DemoAttachment(id: newID(), filename: filename, mimeType: mimeType, created: Date(), data: Data(data))
        let result = edit(key) { $0.attachments.append(attachment) }
        guard result.status == 204 else { return result }
        return ok([["id": attachment.id, "filename": filename, "size": data.count, "mimeType": mimeType]])
    }

    private func newID() -> String {
        state.nextID += 1
        return String(state.nextID)
    }

    // MARK: - Attachments

    private func attachmentData(id: String, thumbnail: Bool) -> Response {
        guard let attachment = state.issues.lazy.flatMap(\.attachments).first(where: { $0.id == id }) else {
            return error(404, "Attachment not found.")
        }
        if let data = attachment.data { return Response(data: data, contentType: attachment.mimeType) }
        if attachment.mimeType.hasPrefix("image/") {
            let key = attachment.id + (thumbnail ? "-thumb" : "")
            if images[key] == nil { images[key] = DemoImages.screenshot(caption: attachment.caption, seed: attachment.filename, scale: thumbnail ? 0.35 : 1) }
            return Response(data: images[key] ?? Data(), contentType: "image/png")
        }
        let log = """
        Incident Identifier: 6F1C2E1A-0B7D-4C5E-9E1A-2D3B4C5D6E7F
        Hardware Model:      iPhone16,2
        Process:             Northwind [4127]
        Version:             2.6.0 (418)
        OS Version:          iPhone OS 26.0

        Exception Type:  EXC_BREAKPOINT (SIGTRAP)
        Termination Reason: Fatal error: Index out of range

        Thread 0 Crashed:
        0   Northwind     RestTimerView.layoutRings(in:) + 212
        1   Northwind     RestTimerView.body.getter + 88
        2   SwiftUICore   ViewGraph.updateOutputs() + 140
        3   UIKitCore     -[UIView layoutSubviews] + 64
        """
        return Response(data: Data(log.utf8), contentType: "text/plain")
    }

    // MARK: - Confluence

    private func confluenceSearch(_ cql: String) -> Response {
        let title = cql.firstMatch(of: /title\s*=\s*"([^"]*)"/).map { String($0.1) }
        guard let title else { return ok(["results": []]) }
        let folders = state.folders.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame && !cql.contains("type = page") }
            .map { ["title": $0.title, "content": ["id": $0.id, "type": "folder", "title": $0.title]] }
        let pages = state.pages.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame && $0.status == "current" && !cql.contains("type = folder") }
            .map { ["title": $0.title, "content": ["id": $0.id, "type": "page", "title": $0.title]] }
        return ok(["results": folders + pages])
    }

    private func folderJSON(_ folder: DemoFolder) -> [String: Any] {
        let slug = folder.title.replacingOccurrences(of: " ", with: "+")
        var result: [String: Any] = [
            "id": folder.id, "title": folder.title, "spaceId": "98301", "type": "folder",
            "_links": ["webui": "/spaces/APP/folder/\(folder.id)/\(slug)", "base": "\(DemoSite.siteURL)/wiki"],
        ]
        if let parent = folder.parentID {
            result["parentId"] = parent
            result["parentType"] = "folder"
        } else {
            result["parentType"] = "space"
        }
        return result
    }

    /// `node` with the `target`th copy of `selection` among its text nodes
    /// highlighted for the inline comment `marker`; `seen` counts the copies
    /// passed. A text node holding the copy splits around it.
    private func highlighting(_ selection: String, at target: Int, marker: String, in node: ADF.Node, seen: inout Int) -> [ADF.Node] {
        if node["type"] as? String == "text", let text = node["text"] as? String {
            let ranges = text.ranges(of: selection)
            let hit = ranges.indices.first { seen + $0 == target }
            seen += ranges.count
            guard let hit else { return [node] }
            let range = ranges[hit]
            var pieces: [ADF.Node] = []
            if range.lowerBound > text.startIndex {
                var before = node
                before["text"] = String(text[..<range.lowerBound])
                pieces.append(before)
            }
            var match = node
            match["text"] = selection
            match["marks"] = (node["marks"] as? [ADF.Node] ?? []) + [["type": "annotation", "attrs": ["annotationType": "inlineComment", "id": marker]]]
            pieces.append(match)
            if range.upperBound < text.endIndex {
                var after = node
                after["text"] = String(text[range.upperBound...])
                pieces.append(after)
            }
            return pieces
        }
        guard let content = node["content"] as? [ADF.Node] else { return [node] }
        var copy = node
        copy["content"] = content.flatMap { highlighting(selection, at: target, marker: marker, in: $0, seen: &seen) }
        return [copy]
    }

    private func pageCommentJSON(_ comment: DemoPageComment) -> [String: Any] {
        let page = state.pages.first { $0.id == comment.pageID }
        let body = (try? JSONSerialization.data(withJSONObject: comment.body, options: [.withoutEscapingSlashes])) ?? Data()
        var result: [String: Any] = [
            "id": comment.id, "status": "current", "pageId": comment.pageID, "resolutionStatus": "open",
            "version": ["number": 1, "authorId": comment.author, "createdAt": stamp(comment.created)],
            "body": ["atlas_doc_format": ["value": String(decoding: body, as: UTF8.self), "representation": "atlas_doc_format"]],
            "_links": ["webui": "/spaces/APP/pages/\(comment.pageID)/\(page?.title ?? "")?focusedCommentId=\(comment.id)"],
        ]
        if let parent = comment.parentID { result["parentCommentId"] = parent }
        if let marker = comment.markerRef { result["properties"] = ["inlineMarkerRef": marker] }
        return result
    }

    private func pageJSON(_ page: DemoPage) -> [String: Any] {
        [
            "id": page.id, "title": page.title, "spaceId": "98301", "parentId": page.parentID, "status": page.status,
            "version": ["number": page.version],
            "body": ["atlas_doc_format": ["value": page.body, "representation": "atlas_doc_format"]],
            "_links": ["webui": "/spaces/APP/pages/\(page.id)/\(page.title)", "base": "\(DemoSite.siteURL)/wiki"],
        ]
    }

    // MARK: - GraphQL

    private func graphQL(_ json: [String: Any]) -> Response {
        let variables = json["variables"] as? [String: Any] ?? [:]
        let query = json["query"] as? String ?? ""
        switch json["operationName"] as? String {
        case "JPlusOrg":
            return ok(["data": ["tenantContexts": [["orgId": "demo-org"]]]])
        case "JPlusTeamSearch":
            let text = (variables["name"] as? String ?? "").lowercased()
            let words = text.split(separator: " ").map(String.init)
            let teams = state.teams.filter { team in words.isEmpty || words.allSatisfy { team.name.lowercased().contains($0) } }
            let withMembers = query.contains("members(")
            return ok(["data": ["team": ["teamSearchV2": ["nodes": teams.map { ["team": teamJSON($0, members: withMembers)] }]]]])
        case "JPlusTeamMembers":
            let id = (variables["id"] as? String ?? "").split(separator: "/").last.map(String.init)
            guard let team = state.teams.first(where: { $0.id == id }) else { return ok(["data": ["team": ["teamV2": NSNull()]]]) }
            return ok(["data": ["team": ["teamV2": teamJSON(team, members: true)]]])
        case "JPlusVersionHighlights":
            let projectID = (variables["projectId"] as? String ?? "").split(separator: "/").last.map(String.init)
            let key = state.projects.first { $0.id == projectID }?.key ?? ""
            let search = (variables["search"] as? String ?? "").lowercased()
            let edges = state.versions.filter { $0.projectKey == key && (search.isEmpty || $0.name.lowercased().contains(search)) }.map { version -> [String: Any] in
                var node: [String: Any] = ["versionId": version.id, "name": version.name, "description": version.description]
                node["richTextSection"] = version.highlights.map { ["title": "Version highlights", "content": ["json": $0]] } ?? NSNull()
                return ["node": node]
            }
            return ok(["data": ["jira": ["versionsForProject": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "edges": edges]]]])
        case "JPlusIssueExtras":
            guard let issue = issue(variables["key"] as? String ?? "") else { return ok(["data": ["jira": ["issueByKey": NSNull()]]]) }
            let designs = issue.designs.map { design -> [String: Any] in
                ["node": ["id": design.id, "displayName": design.name, "url": design.url, "inspectUrl": design.url + "?mode=dev",
                          "status": design.readyForDev ? "READY_FOR_DEVELOPMENT" : "NONE"]]
            }
            let attachments = issue.attachments.map { ["node": ["attachmentId": $0.id, "mediaApiFileId": "media-\($0.filename)"]] }
            return ok(["data": ["jira": ["issueByKey": ["designs": ["edges": designs], "attachments": ["edges": attachments]]]]])
        case "JPlusAddComment":
            let input = variables["input"] as? [String: Any] ?? [:]
            let issueID = (input["issueId"] as? String ?? "").split(separator: "/").last.flatMap { Int($0) }
            let content = (input["content"] as? [String: Any])?["jsonValue"] as? [String: Any] ?? ADF.doc([])
            guard let index = state.issues.firstIndex(where: { $0.id == issueID }) else {
                return ok(["data": ["jira": ["addComment": ["success": false, "errors": [["message": "Issue not found."]]]]]])
            }
            let id = newID()
            state.issues[index].comments.append(DemoComment(id: id, author: me, body: content, created: Date(), parentID: input["threadParentId"] as? String))
            state.issues[index].updated = Date()
            return ok(["data": ["jira": ["addComment": ["success": true, "errors": [], "comment": ["commentId": id]]]]])
        default:
            return ok(["data": NSNull(), "errors": [["message": "Not available in the demo."]]])
        }
    }

    private func teamJSON(_ team: DemoTeam, members: Bool) -> [String: Any] {
        var result: [String: Any] = ["id": "ari:cloud:identity::team/\(team.id)", "displayName": team.name]
        if members {
            result["members"] = [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                "nodes": team.members.map { ["member": ["accountId": $0]] },
            ]
        }
        return result
    }

    // MARK: - JSON

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    private static let calendarDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func stamp(_ date: Date) -> String { Self.timestamp.string(from: date) }

    private func issue(_ key: String) -> DemoIssue? {
        state.issues.first { $0.key.caseInsensitiveCompare(key) == .orderedSame || String($0.id) == key }
    }

    private func project(_ key: String) -> DemoProject? {
        state.projects.first { $0.key.caseInsensitiveCompare(key) == .orderedSame || $0.id == key }
    }

    private func versions(of projectKey: String) -> [DemoVersion] {
        let key = project(projectKey)?.key ?? projectKey
        return state.versions.filter { $0.projectKey == key }
            .sorted { ($0.releaseDate ?? .distantFuture) > ($1.releaseDate ?? .distantFuture) }
    }

    private func userJSON(_ id: String?) -> Any {
        guard let id, let user = state.users.first(where: { $0.id == id }) else { return NSNull() }
        return [
            "accountId": user.id, "displayName": user.name, "emailAddress": user.email, "active": true,
            "timeZone": TimeZone.current.identifier, "locale": "en_US", "accountType": "atlassian",
        ] as [String: Any]
    }

    private func statusJSON(_ status: DemoStatus) -> [String: Any] {
        let color = switch status.category { case "done": "green"; case "indeterminate": "yellow"; default: "blue-gray" }
        return ["id": status.id, "name": status.name, "statusCategory": ["key": status.category, "colorName": color]]
    }

    private func statusJSON(named name: String) -> [String: Any] {
        statusJSON(state.statuses.first { $0.name == name } ?? DemoStatus(id: "1", name: name, category: "new"))
    }

    private func issueTypeJSON(_ type: DemoIssueType) -> [String: Any] {
        ["id": type.id, "name": type.name, "subtask": type.isSubtask, "hierarchyLevel": type.hierarchyLevel]
    }

    private func issueTypeJSON(named name: String) -> [String: Any] {
        issueTypeJSON(state.issueTypes.first { $0.name == name } ?? DemoIssueType(id: "10002", name: name, hierarchyLevel: 0))
    }

    private func priorityJSON(_ name: String) -> [String: Any] {
        ["id": String((state.priorities.firstIndex(of: name) ?? 2) + 1), "name": name]
    }

    private func projectJSON(_ project: DemoProject) -> [String: Any] {
        ["id": project.id, "key": project.key, "name": project.name, "projectTypeKey": "software"]
    }

    private func versionJSON(_ version: DemoVersion, counts: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "id": version.id, "name": version.name, "description": version.description,
            "released": version.released, "archived": version.archived,
            "projectId": Int(project(version.projectKey)?.id ?? "0") ?? 0,
            "overdue": !version.released && (version.releaseDate.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false),
        ]
        if let start = version.startDate { result["startDate"] = Self.calendarDay.string(from: start) }
        if let release = version.releaseDate { result["releaseDate"] = Self.calendarDay.string(from: release) }
        if counts {
            var toDo = 0, inProgress = 0, done = 0
            for issue in state.issues where issue.fixVersions.contains(version.id) {
                switch state.statuses.first(where: { $0.name == issue.status })?.category {
                case "done": done += 1
                case "indeterminate": inProgress += 1
                default: toDo += 1
                }
            }
            result["issuesStatusForFixVersion"] = ["unmapped": 0, "toDo": toDo, "inProgress": inProgress, "done": done]
        }
        return result
    }

    private func refJSON(_ issue: DemoIssue) -> [String: Any] {
        ["id": String(issue.id), "key": issue.key, "fields": [
            "summary": issue.summary, "status": statusJSON(named: issue.status),
            "issuetype": issueTypeJSON(named: issue.type), "priority": priorityJSON(issue.priority),
        ]]
    }

    private func commentJSON(_ comment: DemoComment, withParent: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "id": comment.id, "author": userJSON(comment.author), "updateAuthor": userJSON(comment.author),
            "body": comment.body, "created": stamp(comment.created), "updated": stamp(comment.created),
        ]
        if withParent, let parent = comment.parentID { result["parentId"] = Int(parent) ?? parent }
        return result
    }

    /// The fields a request asked for, or nil for all of them.
    private static func fieldList(_ raw: String?) -> Set<String>? {
        guard let raw, !raw.isEmpty, !raw.contains("*all") else { return nil }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// An issue as Jira returns it, with only the requested fields, as Jira
    /// does: some callers decode every field they get back as one type.
    private func issueJSON(_ issue: DemoIssue, fields wanted: Set<String>?) -> [String: Any] {
        let subtasks = state.issues.filter { $0.parent == issue.key && $0.type == "Sub-task" }.map(refJSON)
        var fields: [String: Any] = [
            "summary": issue.summary,
            "description": issue.description ?? NSNull(),
            "status": statusJSON(named: issue.status),
            "issuetype": issueTypeJSON(named: issue.type),
            "priority": priorityJSON(issue.priority),
            "assignee": userJSON(issue.assignee),
            "reporter": userJSON(issue.reporter),
            "creator": userJSON(issue.reporter),
            "created": stamp(issue.created),
            "updated": stamp(issue.updated),
            "labels": issue.labels,
            "components": issue.components.map { ["name": $0] },
            "fixVersions": issue.fixVersions.compactMap { id in state.versions.first { $0.id == id } }.map { ["id": $0.id, "name": $0.name] },
            "subtasks": subtasks,
            "comment": ["comments": issue.comments.map { commentJSON($0, withParent: false) },
                        "total": issue.comments.count, "maxResults": 100, "startAt": 0],
            "attachment": issue.attachments.map { attachment -> [String: Any] in
                ["id": attachment.id, "filename": attachment.filename, "mimeType": attachment.mimeType,
                 "size": attachment.data?.count ?? (attachment.mimeType.hasPrefix("image/") ? 412_000 : 2_048),
                 "created": stamp(attachment.created)]
            },
            DemoData.teamFieldID: state.teams.first { $0.id == issue.team }.map { ["id": $0.id, "name": $0.name] } ?? NSNull(),
        ]
        if let parentKey = issue.parent, let parent = self.issue(parentKey) {
            fields["parent"] = refJSON(parent)
        }
        if let wanted { fields = fields.filter { wanted.contains($0.key) } }
        return ["id": String(issue.id), "key": issue.key, "self": "\(DemoSite.siteURL)/rest/api/3/issue/\(issue.id)", "fields": fields]
    }

    /// Wiki markup typed into the description or comment editor, as ADF:
    /// paragraphs, and lines starting with "* " or "- " as a bulleted list.
    static func document(fromWiki text: String) -> [String: Any] {
        var blocks: [ADF.Node] = []
        var bullets: [String] = []
        var lines: [String] = []
        func flush() {
            if !lines.isEmpty { blocks.append(ADF.p(lines.joined(separator: "\n"))); lines = [] }
            if !bullets.isEmpty { blocks.append(ADF.bullets(bullets)); bullets = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                if !lines.isEmpty { blocks.append(ADF.p(lines.joined(separator: "\n"))); lines = [] }
                bullets.append(String(line.dropFirst(2)))
            } else {
                if !bullets.isEmpty { blocks.append(ADF.bullets(bullets)); bullets = [] }
                lines.append(line)
            }
        }
        flush()
        return ADF.doc(blocks)
    }

    // MARK: - Responses

    private func ok(_ object: Any, status: Int = 200) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return Response(status: status, data: data)
    }

    private func error(_ status: Int, _ message: String) -> Response {
        ok(["errorMessages": [message], "errors": [:]], status: status)
    }

    private func notFound(_ key: String) -> Response {
        error(404, "Issue \(key) does not exist or you do not have permission to see it.")
    }
}

// MARK: - Sample images

/// Draws a plausible app screenshot for sample image attachments, so issue
/// pages show real pictures without shipping image files.
nonisolated enum DemoImages {
    static func screenshot(caption: String, seed: String, scale: CGFloat) -> Data {
        let width = Int(585 * scale), height = Int(1266 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.scaleBy(x: scale, y: scale)
        // Not hashValue, which changes every launch.
        let hue = CGFloat(seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        let accent = color(hue: hue, saturation: 0.55, brightness: 0.85)

        // Background, status bar area and title bar. CoreGraphics' origin is bottom left.
        context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 585, height: 1266))
        context.setFillColor(accent)
        context.fill(CGRect(x: 0, y: 1266 - 230, width: 585, height: 230))
        draw(caption.isEmpty ? "Northwind" : caption, at: CGPoint(x: 36, y: 1266 - 170), size: 40, color: CGColor(gray: 1, alpha: 1), in: context)
        draw("Northwind Fitness", at: CGPoint(x: 36, y: 1266 - 110), size: 22, color: CGColor(gray: 1, alpha: 0.85), in: context)

        // Cards.
        var y: CGFloat = 1266 - 290
        for index in 0..<5 {
            let cardHeight: CGFloat = index == 0 ? 220 : 150
            y -= cardHeight
            let card = CGRect(x: 28, y: y, width: 529, height: cardHeight)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
            context.fillPath()
            context.setFillColor(color(hue: hue + CGFloat(index) * 0.08, saturation: 0.35, brightness: 0.95))
            context.addPath(CGPath(roundedRect: CGRect(x: 52, y: y + cardHeight - 110, width: 86, height: 86), cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            context.fill(CGRect(x: 160, y: y + cardHeight - 52, width: 300, height: 18))
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: 160, y: y + cardHeight - 86, width: 220, height: 14))
            if index == 0 {
                context.setFillColor(accent)
                context.addPath(CGPath(roundedRect: CGRect(x: 52, y: y + 28, width: 481, height: 56), cornerWidth: 28, cornerHeight: 28, transform: nil))
                context.fillPath()
                draw("Download", at: CGPoint(x: 240, y: y + 46), size: 24, color: CGColor(gray: 1, alpha: 1), in: context)
            }
            y -= 22
        }

        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        // HSB to RGB, without AppKit or UIKit.
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
