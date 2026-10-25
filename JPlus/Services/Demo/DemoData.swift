import Foundation

// The sample site behind the App Review demo: a small fitness-app company
// with a mobile app, a web dashboard and a platform project. Dates are
// relative to launch, so "updated 3 hours ago" stays true whenever the
// reviewer looks.

nonisolated struct DemoUser: Sendable {
    let id: String
    let name: String
    let email: String
}

nonisolated struct DemoStatus: Sendable {
    let id: String
    let name: String
    /// "new", "indeterminate" or "done".
    let category: String
}

nonisolated struct DemoIssueType: Sendable {
    let id: String
    let name: String
    let hierarchyLevel: Int
    var isSubtask: Bool { hierarchyLevel < 0 }
}

nonisolated struct DemoComment: @unchecked Sendable {
    let id: String
    let author: String
    var body: [String: Any]
    let created: Date
    var parentID: String?
}

nonisolated struct DemoAttachment: Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let created: Date
    /// Uploaded bytes; nil for sample files, which are drawn on request.
    var data: Data?
    /// Heading drawn on a sample image.
    var caption: String = ""
}

nonisolated struct DemoDesign: Sendable {
    let id: String
    let name: String
    let url: String
    let readyForDev: Bool
}

nonisolated struct DemoIssue: @unchecked Sendable {
    let id: Int
    let key: String
    var type: String
    var summary: String
    var description: [String: Any]?
    var status: String
    var priority: String
    var assignee: String?
    var reporter: String
    let created: Date
    var updated: Date
    var labels: [String] = []
    var components: [String] = []
    var fixVersions: [String] = []
    var parent: String?
    var comments: [DemoComment] = []
    var attachments: [DemoAttachment] = []
    var designs: [DemoDesign] = []
    var team: String?
    var watchers: [String] = []
    var rank: Int = 0

    var projectKey: String { String(key.prefix { $0 != "-" }) }
    var number: Int { Int(key.split(separator: "-").last ?? "") ?? 0 }
}

nonisolated struct DemoProject: Sendable {
    let id: String
    let key: String
    let name: String
}

nonisolated struct DemoVersion: @unchecked Sendable {
    let id: String
    let projectKey: String
    let name: String
    let description: String
    var released: Bool
    var archived: Bool
    let startDate: Date?
    let releaseDate: Date?
    var highlights: [String: Any]?
}

nonisolated struct DemoTeam: Sendable {
    let id: String
    let name: String
    let members: [String]
}

nonisolated struct DemoFolder: Sendable {
    let id: String
    let title: String
    let parentID: String?
}

nonisolated struct DemoPage: Sendable {
    let id: String
    var title: String
    let parentID: String
    var version: Int
    /// ADF as a JSON string, as Confluence stores it.
    var body: String
}

/// An open inline comment on a day page, or a reply to one.
nonisolated struct DemoPageComment: @unchecked Sendable {
    let id: String
    let pageID: String
    let author: String
    let body: [String: Any]
    let created: Date
    /// The highlight in the page's text; nil for a reply.
    let markerRef: String?
    var parentID: String?
}

nonisolated struct DemoState: @unchecked Sendable {
    var users: [DemoUser]
    var statuses: [DemoStatus]
    var priorities: [String]
    var issueTypes: [DemoIssueType]
    var projects: [DemoProject]
    var versions: [DemoVersion]
    var teams: [DemoTeam]
    var issues: [DemoIssue]
    var folders: [DemoFolder]
    var pages: [DemoPage]
    var pageComments: [DemoPageComment]
    var nextID: Int = 50_000
}

// MARK: - ADF

/// Builds Atlassian Document Format as JSON dictionaries.
nonisolated enum ADF {
    typealias Node = [String: Any]

    static func doc(_ blocks: [Node]) -> Node { ["type": "doc", "version": 1, "content": blocks] }

    /// A paragraph from strings and inline nodes.
    static func p(_ parts: Any...) -> Node {
        ["type": "paragraph", "content": parts.map { part -> Node in
            if let text = part as? String { return t(text) }
            return part as? Node ?? t("")
        }]
    }

    static func t(_ text: String) -> Node { ["type": "text", "text": text] }
    static func bold(_ text: String) -> Node { ["type": "text", "text": text, "marks": [["type": "strong"]]] }
    static func code(_ text: String) -> Node { ["type": "text", "text": text, "marks": [["type": "code"]]] }
    static func link(_ text: String, _ href: String) -> Node {
        ["type": "text", "text": text, "marks": [["type": "link", "attrs": ["href": href]]]]
    }
    static func mention(_ user: DemoUser) -> Node {
        ["type": "mention", "attrs": ["id": user.id, "text": "@\(user.name)", "accessLevel": ""]]
    }

    static func heading(_ text: String, level: Int = 3) -> Node {
        ["type": "heading", "attrs": ["level": level], "content": [t(text)]]
    }

    static func bullets(_ items: [Any]) -> Node { list("bulletList", items) }
    static func numbered(_ items: [Any]) -> Node { list("orderedList", items) }

    private static func list(_ type: String, _ items: [Any]) -> Node {
        ["type": type, "content": items.map { item -> Node in
            let paragraph = (item as? Node) ?? p(item as? String ?? "")
            return ["type": "listItem", "content": [paragraph]]
        }]
    }

    static func codeBlock(_ text: String, language: String = "") -> Node {
        ["type": "codeBlock", "attrs": ["language": language], "content": [t(text)]]
    }

    static func panel(_ kind: String, _ text: String) -> Node {
        ["type": "panel", "attrs": ["panelType": kind], "content": [p(text)]]
    }

    static func rule() -> Node { ["type": "rule"] }

    /// An image attachment shown in the text, matched to the attachment by file name.
    static func image(_ filename: String, width: Int = 1170, height: Int = 2532) -> Node {
        ["type": "mediaSingle", "attrs": ["layout": "center"], "content": [[
            "type": "media",
            "attrs": ["type": "file", "id": "media-\(filename)", "collection": "", "alt": filename, "width": width, "height": height],
        ]]]
    }

    static func task(_ parts: [Any], done: Bool = false) -> Node {
        ["type": "taskItem", "attrs": ["localId": UUID().uuidString.lowercased(), "state": done ? "DONE" : "TODO"],
         "content": parts.map { part -> Node in (part as? Node) ?? t(part as? String ?? "") }]
    }

    /// Text with an inline comment's highlight, which `markerRef` names.
    static func commented(_ text: String, markerRef: String) -> Node {
        ["type": "text", "text": text, "marks": [["type": "annotation", "attrs": ["annotationType": "inlineComment", "id": markerRef]]]]
    }

    static func taskList(_ items: [Node]) -> Node {
        ["type": "taskList", "attrs": ["localId": UUID().uuidString.lowercased()], "content": items]
    }

    /// The text of a tree, block by block, for search and wiki-markup views.
    static func plainText(_ node: Any?) -> String {
        guard let node = node as? Node else { return "" }
        if let text = node["text"] as? String { return text }
        let type = node["type"] as? String ?? ""
        if type == "mention" { return ((node["attrs"] as? Node)?["text"] as? String) ?? "" }
        if type == "hardBreak" { return "\n" }
        let children = (node["content"] as? [Node]) ?? []
        let blocks: Set<String> = ["doc", "bulletList", "orderedList", "panel", "taskList"]
        if blocks.contains(type) {
            return children.map { plainText($0) }.joined(separator: "\n")
        }
        let text = children.map { plainText($0) }.joined()
        if type == "listItem" { return "* " + text }
        return text
    }

    /// Whether `user` is @-mentioned anywhere in the tree.
    static func mentions(_ node: Any?, user: String) -> Bool {
        guard let node = node as? Node else { return false }
        if node["type"] as? String == "mention", (node["attrs"] as? Node)?["id"] as? String == user { return true }
        return ((node["content"] as? [Node]) ?? []).contains { mentions($0, user: user) }
    }
}

// MARK: - Seed

nonisolated enum DemoData {
    static let reviewer = DemoUser(id: "demo-reviewer", name: "App Reviewer", email: DemoSite.email)
    static let maya = DemoUser(id: "demo-maya", name: "Maya Chen", email: "maya@northwind.example")
    static let diego = DemoUser(id: "demo-diego", name: "Diego Alvarez", email: "diego@northwind.example")
    static let priya = DemoUser(id: "demo-priya", name: "Priya Natarajan", email: "priya@northwind.example")
    static let sam = DemoUser(id: "demo-sam", name: "Sam Okafor", email: "sam@northwind.example")
    static let lena = DemoUser(id: "demo-lena", name: "Lena Fischer", email: "lena@northwind.example")
    static let tom = DemoUser(id: "demo-tom", name: "Tom Becker", email: "tom@northwind.example")
    static let ava = DemoUser(id: "demo-ava", name: "Ava Thompson", email: "ava@northwind.example")

    static let teamFieldID = "customfield_10001"

    static func make(now: Date) -> DemoState {
        let calendar = Calendar.current
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }

        let statuses = [
            DemoStatus(id: "1", name: "To Do", category: "new"),
            DemoStatus(id: "3", name: "In Progress", category: "indeterminate"),
            DemoStatus(id: "4", name: "In Review", category: "indeterminate"),
            DemoStatus(id: "5", name: "Ready for QA", category: "indeterminate"),
            DemoStatus(id: "6", name: "QA", category: "indeterminate"),
            DemoStatus(id: "10", name: "Done", category: "done"),
            DemoStatus(id: "11", name: "Won't Do", category: "done"),
        ]
        let issueTypes = [
            DemoIssueType(id: "10000", name: "Epic", hierarchyLevel: 1),
            DemoIssueType(id: "10001", name: "Story", hierarchyLevel: 0),
            DemoIssueType(id: "10002", name: "Task", hierarchyLevel: 0),
            DemoIssueType(id: "10003", name: "Bug", hierarchyLevel: 0),
            DemoIssueType(id: "10004", name: "Sub-task", hierarchyLevel: -1),
        ]
        let projects = [
            DemoProject(id: "10010", key: "APP", name: "Mobile App"),
            DemoProject(id: "10020", key: "WEB", name: "Web Dashboard"),
            DemoProject(id: "10030", key: "OPS", name: "Platform"),
        ]

        // MARK: Versions
        var versions = [
            DemoVersion(id: "20230", projectKey: "APP", name: "2.3.0", description: "Spring release", released: true, archived: true,
                        startDate: day(-150), releaseDate: day(-120)),
            DemoVersion(id: "20240", projectKey: "APP", name: "2.4.0", description: "Onboarding refresh", released: true, archived: false,
                        startDate: day(-80), releaseDate: day(-49)),
            DemoVersion(id: "20250", projectKey: "APP", name: "2.5.0", description: "Streaks and dark mode fixes", released: true, archived: false,
                        startDate: day(-45), releaseDate: day(-12)),
            DemoVersion(id: "20260", projectKey: "APP", name: "2.6.0", description: "Offline workouts and Health sync", released: false, archived: false,
                        startDate: day(-11), releaseDate: day(9)),
            DemoVersion(id: "20270", projectKey: "APP", name: "2.7.0", description: "Widgets and sharing", released: false, archived: false,
                        startDate: day(10), releaseDate: day(42)),
            DemoVersion(id: "30100", projectKey: "WEB", name: "Coach Dashboard 1.0", description: "First release for coaches", released: false, archived: false,
                        startDate: day(-30), releaseDate: day(16)),
            DemoVersion(id: "40100", projectKey: "OPS", name: "Q4 Hardening", description: "Reliability work for the holiday peak", released: false, archived: false,
                        startDate: day(-20), releaseDate: day(30)),
        ]
        versions[3].highlights = ADF.doc([
            ADF.p("Take workouts anywhere: download a plan and train with no connection. Workouts now also go straight to Apple Health as they finish."),
            ADF.bullets([
                "Offline plans with a storage limit and Wi-Fi only downloads",
                "Apple Health writes, with fixed duplicate heart rate samples",
                "Weekly summary notification",
            ]),
        ])
        versions[2].highlights = ADF.doc([
            ADF.p("Streaks on the home screen, plus a round of dark mode and paywall fixes."),
        ])

        let teams = [
            DemoTeam(id: "team-app", name: "App Team", members: [reviewer.id, maya.id, diego.id, priya.id, sam.id, ava.id]),
            DemoTeam(id: "team-web", name: "Web Team", members: [lena.id, tom.id]),
            DemoTeam(id: "team-platform", name: "Platform Team", members: [tom.id]),
        ]

        // MARK: Issues
        var nextID = 10_100
        var issues: [DemoIssue] = []
        func add(_ key: String, _ type: String, _ summary: String, status: String, priority: String = "Medium",
                 assignee: DemoUser?, reporter: DemoUser, created: Date, updated: Date,
                 versions: [String] = [], parent: String? = nil, labels: [String] = [], components: [String] = [],
                 team: String? = nil, description: [ADF.Node]? = nil,
                 comments: [(DemoUser, Date, [ADF.Node], String?)] = [],
                 attachments: [(String, String, String)] = [], designs: [DemoDesign] = []) {
            nextID += 1
            var issue = DemoIssue(id: nextID, key: key, type: type, summary: summary,
                                  description: description.map(ADF.doc), status: status, priority: priority,
                                  assignee: assignee?.id, reporter: reporter.id, created: created, updated: updated)
            issue.fixVersions = versions
            issue.parent = parent
            issue.labels = labels
            issue.components = components
            issue.team = team
            issue.rank = issues.count
            issue.watchers = [reporter.id] + (assignee.map { [$0.id] } ?? [])
            issue.comments = comments.enumerated().map { index, comment in
                DemoComment(id: "\(nextID)\(index)", author: comment.0.id, body: ADF.doc(comment.2),
                            created: comment.1, parentID: comment.3)
            }
            issue.attachments = attachments.enumerated().map { index, file in
                DemoAttachment(id: "\(nextID)\(index + 5)", filename: file.0, mimeType: file.1, created: created, caption: file.2)
            }
            issue.designs = designs
            issues.append(issue)
        }

        // Mobile App — Offline workouts
        add("APP-101", "Epic", "Offline workouts", status: "In Progress", priority: "High", assignee: maya, reporter: maya,
            created: daysAgo(41), updated: daysAgo(1), versions: ["20260"], team: "team-app",
            description: [
                ADF.p("Members train in basements, on planes and on trails. Today the app needs a connection to start a workout; this epic makes a downloaded plan work fully offline."),
                ADF.heading("Goals"),
                ADF.bullets(["Download a plan, videos included", "Record a workout offline and sync it later", "Never surprise people with mobile data use"]),
                ADF.heading("Out of scope"),
                ADF.p("Live classes, which stay online only."),
            ])
        add("APP-110", "Story", "Download a workout plan for offline use", status: "In Progress", priority: "High",
            assignee: reviewer, reporter: maya, created: daysAgo(18), updated: hoursAgo(3), versions: ["20260"],
            parent: "APP-101", labels: ["offline"], components: ["iOS", "Android"], team: "team-app",
            description: [
                ADF.p("As a member, I want to download a plan before I leave home, so that I can follow it without a connection."),
                ADF.heading("Acceptance criteria"),
                ADF.numbered([
                    "A Download button on the plan screen saves every workout in the plan.",
                    "Downloaded plans show a check mark on their card.",
                    "Starting a downloaded workout works in Airplane Mode.",
                    "Removing the download frees its storage straight away.",
                ]),
                ADF.image("offline-plan-flow.png"),
                ADF.p("Design: ", ADF.link("Offline plans in Figma", "https://www.figma.com/design/northwind-offline-plans")),
            ],
            comments: [
                (maya, daysAgo(4), [ADF.p(ADF.mention(reviewer), " can you confirm we keep the plan's videos at 720p? Ava's mock assumes about 400 MB for a 12-week plan.")], nil),
                (reviewer, daysAgo(3.8), [ADF.p("Yes, 720p. 1080p roughly doubles it, and nobody could tell the difference on a phone in testing.")], "\(nextID + 1)0"),
                (ava, daysAgo(2), [ADF.p("Updated the mock with the storage estimate under the Download button.")], nil),
                (diego, hoursAgo(5), [ADF.p("Download manager is merged behind the ", ADF.code("offlinePlans"), " flag. ", ADF.mention(reviewer), " the plan screen is yours whenever you're ready.")], nil),
            ],
            attachments: [("offline-plan-flow.png", "image/png", "Offline plan flow")],
            designs: [DemoDesign(id: "design-1", name: "Offline plans — download flow", url: "https://www.figma.com/design/northwind-offline-plans", readyForDev: true)])
        add("APP-111", "Task", "Cache exercise videos with a size limit", status: "In Review", assignee: diego, reporter: diego,
            created: daysAgo(16), updated: hoursAgo(20), versions: ["20260"], parent: "APP-101", labels: ["offline"],
            components: ["iOS"], team: "team-app",
            description: [
                ADF.p("Keep downloaded videos under a limit the member picks in Settings (default 2 GB). When a new download would go over it, remove the least recently watched videos first."),
                ADF.codeBlock("let limit = Settings.shared.offlineStorageLimit // bytes\ntry await videoCache.makeRoom(for: plan.totalSize, within: limit)", language: "swift"),
            ],
            comments: [(sam, hoursAgo(20), [ADF.p("Tested with a 500 MB limit and three plans; oldest videos went first as expected.")], nil)])
        add("APP-112", "Sub-task", "Remove least recently watched videos first", status: "Done", assignee: diego, reporter: diego,
            created: daysAgo(15), updated: daysAgo(6), versions: ["20260"], parent: "APP-111", team: "team-app",
            description: [ADF.p("LRU order by last playback date, not download date.")])
        add("APP-113", "Sub-task", "Settings toggle for Wi-Fi only downloads", status: "To Do", assignee: reviewer, reporter: diego,
            created: daysAgo(15), updated: daysAgo(2), versions: ["20260"], parent: "APP-111", team: "team-app",
            description: [ADF.p("On by default. When off, warn once before a download over 100 MB on cellular.")])
        add("APP-114", "Bug", "Offline banner stays after the connection comes back", status: "To Do", priority: "High",
            assignee: reviewer, reporter: sam, created: daysAgo(3), updated: hoursAgo(26), versions: ["20260"],
            parent: "APP-101", labels: ["offline", "regression"], components: ["iOS"], team: "team-app",
            description: [
                ADF.heading("Steps"),
                ADF.numbered(["Turn on Airplane Mode and open a downloaded plan.", "Turn Airplane Mode off.", "Wait 30 seconds."]),
                ADF.heading("Expected"),
                ADF.p("The \"You're offline\" banner disappears."),
                ADF.heading("Actual"),
                ADF.p("It stays until the app is restarted."),
                ADF.image("offline-banner.png"),
                ADF.p(ADF.bold("Device: "), "iPhone 15, iOS 26.0"),
            ],
            attachments: [("offline-banner.png", "image/png", "Offline banner")])
        add("APP-115", "Story", "Show download progress on the plan card", status: "Ready for QA", assignee: priya, reporter: maya,
            created: daysAgo(12), updated: daysAgo(1), versions: ["20260"], parent: "APP-101", components: ["Android"], team: "team-app",
            description: [ADF.p("A thin progress ring around the plan's icon while it downloads, with the percentage for VoiceOver.")])

        // Mobile App — Apple Health sync v2
        add("APP-102", "Epic", "Apple Health sync v2", status: "In Progress", priority: "High", assignee: diego, reporter: maya,
            created: daysAgo(38), updated: daysAgo(2), versions: ["20260", "20270"], team: "team-app",
            description: [ADF.p("Write each workout to Apple Health the moment it ends, read resting heart rate back, and ask for permission when it's first needed rather than at launch.")])
        add("APP-120", "Story", "Write workouts to Apple Health as they finish", status: "QA", assignee: diego, reporter: maya,
            created: daysAgo(30), updated: hoursAgo(9), versions: ["20260"], parent: "APP-102", components: ["iOS"], team: "team-app",
            description: [ADF.p("Today workouts sync to Health once a day. Write them as soon as the summary screen appears, with route, heart rate and active energy.")],
            comments: [(sam, hoursAgo(9), [ADF.p("Looks good on watchOS 26 and iOS 26. Testing older devices next.")], nil)])
        add("APP-121", "Bug", "Heart rate samples duplicated after a sync", status: "In Progress", priority: "Highest",
            assignee: reviewer, reporter: sam, created: daysAgo(6), updated: hoursAgo(2), versions: ["20260"], parent: "APP-102",
            labels: ["health"], components: ["iOS"], team: "team-app",
            description: [
                ADF.p("After a workout syncs twice (for example after reinstalling), Apple Health shows every heart rate sample twice and the average is wrong."),
                ADF.panel("warning", "Blocks 2.6.0: Health data written wrongly can't be cleaned up for people automatically."),
                ADF.p("Probably we don't set ", ADF.code("HKMetadataKeySyncIdentifier"), " on the samples."),
            ],
            comments: [
                (sam, daysAgo(5), [ADF.p("Reproduced on two devices. Screenshot of Health attached.")], nil),
                (diego, daysAgo(4.5), [ADF.p("Confirmed: we only set the sync identifier on the workout, not the samples.")], "\(nextID + 1)0"),
                (sam, hoursAgo(4), [ADF.p(ADF.mention(reviewer), " is a fix likely for the 2.6.0 build on Thursday? I'd like a day of testing on it.")], nil),
            ],
            attachments: [("health-duplicates.png", "image/png", "Duplicate samples")])
        add("APP-122", "Task", "Ask for Health permission at the first workout, not at launch", status: "Done", assignee: priya, reporter: maya,
            created: daysAgo(28), updated: daysAgo(9), versions: ["20260"], parent: "APP-102", team: "team-app",
            description: [ADF.p("App Review asked us to explain why we need Health before asking. Show a short explanation screen first.")])
        add("APP-123", "Story", "Read resting heart rate from Apple Health", status: "To Do", assignee: priya, reporter: maya,
            created: daysAgo(20), updated: daysAgo(7), versions: ["20270"], parent: "APP-102", team: "team-app",
            description: [ADF.p("Use resting heart rate to suggest an easier day when it's well above the member's usual.")])

        // Mobile App — standalone work in 2.6.0
        add("APP-125", "Bug", "Crash when rotating the phone during the rest timer", status: "To Do", priority: "Highest",
            assignee: reviewer, reporter: sam, created: daysAgo(2), updated: hoursAgo(7), versions: ["20260"],
            labels: ["crash"], components: ["iOS"], team: "team-app",
            description: [
                ADF.p("Crashes about one time in five when rotating to landscape while the rest timer counts down. 41 crashes in TestFlight this week."),
                ADF.codeBlock("Fatal error: Index out of range\n0  Northwind  RestTimerView.layoutRings(in:) + 212\n1  Northwind  RestTimerView.body.getter + 88\n2  SwiftUICore  ViewGraph.updateOutputs() + 140", language: "text"),
                ADF.image("rest-timer.png"),
            ],
            comments: [(diego, hoursAgo(7), [ADF.p(ADF.mention(reviewer), " the ring count goes to zero for one frame during rotation. Guarding the empty case should do it.")], nil)],
            attachments: [("rest-timer.png", "image/png", "Rest timer"), ("crash-log.txt", "text/plain", "")])
        add("APP-126", "Bug", "VoiceOver reads the workout timer twice", status: "In Progress", assignee: priya, reporter: sam,
            created: daysAgo(8), updated: daysAgo(1), versions: ["20260"], labels: ["accessibility"], components: ["Android"], team: "team-app",
            description: [ADF.p("TalkBack and VoiceOver both read \"12 minutes 30 seconds, 12 minutes 30 seconds\". The label and value are both set.")])
        add("APP-127", "Task", "Update App Store screenshots for 2.6", status: "To Do", priority: "Low", assignee: ava, reporter: maya,
            created: daysAgo(5), updated: daysAgo(5), versions: ["20260"], team: "team-app",
            description: [ADF.p("Six screenshots at 6.9\" and 13\", leading with offline plans.")])
        add("APP-128", "Story", "Weekly summary notification", status: "Ready for QA", assignee: diego, reporter: maya,
            created: daysAgo(22), updated: daysAgo(3), versions: ["20260"], components: ["iOS", "Android"], team: "team-app",
            description: [ADF.p("Sunday at 6 pm local time: workouts done, minutes trained and the streak. Off for anyone who turned off notifications.")])
        add("APP-131", "Task", "Remove the legacy login screen", status: "In Review", priority: "Low", assignee: reviewer, reporter: priya,
            created: daysAgo(10), updated: daysAgo(1.5), versions: ["20260"], team: "team-app",
            description: [ADF.p("Everyone has been on Sign in with Apple or email links since 2.3. Delete ", ADF.code("LegacyLoginView"), " and its tests.")],
            comments: [
                (priya, daysAgo(2), [ADF.p("Android side is gone too. 1,200 fewer lines.")], nil),
                (reviewer, daysAgo(1.6), [ADF.p("Nice. Pull request is up for iOS.")], nil),
                (priya, daysAgo(1.5), [ADF.p(ADF.mention(reviewer), " approved, just one comment about the analytics event.")], nil),
            ])

        // Mobile App — 2.7.0 and backlog
        add("APP-133", "Story", "Share a finished workout as an image", status: "To Do", assignee: nil, reporter: maya,
            created: daysAgo(14), updated: daysAgo(14), versions: ["20270"], team: "team-app",
            description: [ADF.p("A card with the workout, time and route map, ready for Messages or Instagram Stories.")])
        add("APP-140", "Story", "Widgets for today's workout", status: "To Do", assignee: reviewer, reporter: maya,
            created: daysAgo(9), updated: daysAgo(4), versions: ["20270"], components: ["iOS"], team: "team-app",
            description: [ADF.p("Small and medium Home Screen widgets, plus a Lock Screen one, showing today's workout and a Start button.")],
            designs: [DemoDesign(id: "design-2", name: "Widgets — today's workout", url: "https://www.figma.com/design/northwind-widgets", readyForDev: false)])
        add("APP-135", "Story", "Support iOS 16", status: "Won't Do", priority: "Low", assignee: nil, reporter: sam,
            created: daysAgo(60), updated: daysAgo(55), team: "team-app",
            description: [ADF.p("Under 1% of members are on iOS 16; we're keeping iOS 17 as the minimum.")])

        // Mobile App — shipped
        add("APP-103", "Epic", "Onboarding refresh", status: "Done", assignee: maya, reporter: maya,
            created: daysAgo(95), updated: daysAgo(49), versions: ["20240"], team: "team-app",
            description: [ADF.p("Shorter onboarding that asks about goals before showing plans.")])
        add("APP-137", "Story", "New welcome carousel", status: "Done", assignee: ava, reporter: maya,
            created: daysAgo(90), updated: daysAgo(50), versions: ["20240"], parent: "APP-103", team: "team-app",
            description: [ADF.p("Three screens instead of five.")])
        add("APP-138", "Story", "Ask about goals during onboarding", status: "Done", assignee: diego, reporter: maya,
            created: daysAgo(88), updated: daysAgo(51), versions: ["20240"], parent: "APP-103", team: "team-app",
            description: [ADF.p("Strength, endurance or general fitness, used to pick the first plan.")])
        add("APP-129", "Bug", "Dark mode: chart labels are unreadable", status: "Done", assignee: priya, reporter: sam,
            created: daysAgo(30), updated: daysAgo(13), versions: ["20250"], labels: ["dark-mode"], team: "team-app",
            description: [ADF.p("Axis labels use black text on the dark background.")])
        add("APP-130", "Story", "Streaks on the home screen", status: "Done", assignee: diego, reporter: maya,
            created: daysAgo(40), updated: daysAgo(13), versions: ["20250"], team: "team-app",
            description: [ADF.p("Show the current streak with a flame icon above today's workout.")])
        add("APP-132", "Bug", "Typo on the paywall: \"anual\"", status: "Done", priority: "Low", assignee: ava, reporter: reviewer,
            created: daysAgo(25), updated: daysAgo(14), versions: ["20250"], team: "team-app",
            description: [ADF.p("Should be \"annual\".")])
        add("APP-134", "Bug", "Sign-in fails with a + in the email address", status: "Done", priority: "High", assignee: reviewer, reporter: sam,
            created: daysAgo(33), updated: daysAgo(15), versions: ["20250"], team: "team-app",
            description: [ADF.p("Addresses like ", ADF.code("name+fitness@example.com"), " are rejected as invalid.")])

        // Web Dashboard
        add("WEB-21", "Epic", "Coach dashboard", status: "In Progress", assignee: lena, reporter: maya,
            created: daysAgo(35), updated: daysAgo(1), versions: ["30100"], team: "team-web",
            description: [ADF.p("A web dashboard where coaches follow their clients' training and adjust plans.")])
        add("WEB-22", "Story", "Coaches see each client's progress charts", status: "In Progress", assignee: lena, reporter: maya,
            created: daysAgo(20), updated: hoursAgo(11), versions: ["30100"], parent: "WEB-21", team: "team-web",
            description: [ADF.p("Weekly minutes, workouts completed and personal bests, over 4, 12 or 52 weeks.")])
        add("WEB-23", "Bug", "CSV export cuts off names that contain commas", status: "To Do", assignee: tom, reporter: lena,
            created: daysAgo(4), updated: daysAgo(1), versions: ["30100"], team: "team-web",
            description: [
                ADF.p("Exporting a client list with \"Okafor, Sam\" splits the name into two columns. We need to quote fields."),
                ADF.p(ADF.mention(reviewer), " the mobile app's export has the same code path; worth checking before 2.6.0."),
            ])
        add("WEB-24", "Task", "Move charts to the new design tokens", status: "In Review", assignee: lena, reporter: ava,
            created: daysAgo(9), updated: daysAgo(2), versions: ["30100"], team: "team-web",
            description: [ADF.p("Replace hard-coded colors with tokens so charts match the app in dark mode.")])
        add("WEB-25", "Story", "Invite clients by link", status: "Done", assignee: lena, reporter: maya,
            created: daysAgo(28), updated: daysAgo(10), versions: ["30100"], parent: "WEB-21", team: "team-web",
            description: [ADF.p("Coaches share a link; clients who open it on a phone get the app with the coach already connected.")])
        add("WEB-26", "Bug", "Session expires too soon in Safari", status: "QA", priority: "High", assignee: tom, reporter: reviewer,
            created: daysAgo(7), updated: daysAgo(1), versions: ["30100"], team: "team-web",
            description: [ADF.p("Safari users are signed out after about an hour; other browsers stay signed in for a week. Likely the cookie's SameSite setting.")],
            comments: [(tom, daysAgo(1), [ADF.p(ADF.mention(reviewer), " fixed on staging, could you check with your Safari profile?")], nil)])

        // Platform
        add("OPS-7", "Task", "Renew push notification certificates", status: "To Do", priority: "High", assignee: reviewer, reporter: tom,
            created: daysAgo(6), updated: daysAgo(2), versions: ["40100"], team: "team-platform",
            description: [ADF.p("The APNs certificate expires in 19 days. Move to token-based auth so this doesn't come back every year.")])
        add("OPS-8", "Task", "Alert when the sync queue backs up", status: "In Progress", assignee: tom, reporter: tom,
            created: daysAgo(11), updated: hoursAgo(15), versions: ["40100"], team: "team-platform",
            description: [ADF.p("Page the on-call engineer when more than 5,000 workouts wait over 10 minutes.")])
        add("OPS-9", "Bug", "Nightly backup job timed out", status: "Done", priority: "High", assignee: tom, reporter: tom,
            created: daysAgo(19), updated: daysAgo(17), versions: ["40100"], team: "team-platform",
            description: [ADF.p("The backup ran past its 2-hour limit after the workouts table passed 400 million rows. Split it per month.")])

        // MARK: Daily Priorities
        let folders = [
            DemoFolder(id: "900", title: "Mobile App", parentID: nil),
            DemoFolder(id: "901", title: "Daily Priorities", parentID: "900"),
        ]
        var allFolders = folders
        var pages: [DemoPage] = []
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = Calendar(identifier: .gregorian)
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        // A comment on today's crash item, with a reply.
        let crashMarker = "5f0c2a9e-7d41-4b8e-9a36-2c1e8f4d7b10"
        let dayItems: [[ADF.Node]] = [
            [ADF.task(["APP-121: fix duplicate heart rate samples before Thursday's build"]),
             ADF.task(["Review ", ADF.mention(diego), "'s video cache pull request (APP-111)"]),
             ADF.task(["APP-125: ", ADF.commented("rest timer crash, 41 reports this week", markerRef: crashMarker)]),
             ADF.task(["Check WEB-26 on staging in Safari"], done: true)],
            [ADF.task(["APP-110: plan screen Download button"], done: true),
             ADF.task(["Answer ", ADF.mention(sam), " about the 2.6.0 test plan"], done: true),
             ADF.task(["APP-121: reproduce with a reinstall"])],
            [ADF.task(["Release notes for 2.6.0"], done: true),
             ADF.task(["APP-131: address review comment on analytics"], done: true),
             ADF.task(["OPS-7: plan the move to token-based push"])],
            [ADF.task(["Kick-off for widgets (APP-140) with ", ADF.mention(ava)], done: true),
             ADF.task(["APP-114: offline banner investigation"], done: false)],
            [ADF.task(["Sprint planning"], done: true),
             ADF.task(["Triage new crash reports"], done: true),
             ADF.task(["Update the offline storage estimate in Figma"], done: true)],
            [ADF.task(["App Store screenshots brief for 2.6 (APP-127)"], done: true),
             ADF.task(["1:1 with ", ADF.mention(maya)], done: true)],
        ]
        var workdays: [Date] = []
        var cursor = calendar.startOfDay(for: now)
        while workdays.count < dayItems.count {
            if !calendar.isDateInWeekend(cursor) || workdays.isEmpty { workdays.append(cursor) }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var monthIDs: [String: String] = [:]
        for (index, date) in workdays.enumerated() {
            let month = monthFormatter.string(from: date)
            if monthIDs[month] == nil {
                let id = String(902 + monthIDs.count)
                monthIDs[month] = id
                allFolders.append(DemoFolder(id: id, title: month, parentID: "901"))
            }
            let document = ADF.doc([ADF.taskList(dayItems[index])])
            let json = (try? JSONSerialization.data(withJSONObject: document, options: [.withoutEscapingSlashes])) ?? Data()
            pages.append(DemoPage(id: String(1000 + index), title: dayFormatter.string(from: date), parentID: monthIDs[month]!,
                                  version: 1, body: String(decoding: json, as: UTF8.self)))
        }

        // Product Questions, beside the Daily Priorities folder.
        let questions = ADF.doc([ADF.taskList([
            ADF.task(["Ask ", ADF.mention(sam), " whether 2.6.0 can ship without the widgets (APP-140)"]),
            ADF.task(["Should the offline banner (APP-114) show on the web app too?"]),
            ADF.task(["Confirm the rest timer keeps counting when the phone locks"], done: true),
        ])])
        let questionsJSON = (try? JSONSerialization.data(withJSONObject: questions, options: [.withoutEscapingSlashes])) ?? Data()
        pages.append(DemoPage(id: "1100", title: "Product Questions", parentID: "900",
                              version: 1, body: String(decoding: questionsJSON, as: UTF8.self)))

        return DemoState(
            users: [reviewer, maya, diego, priya, sam, lena, tom, ava],
            statuses: statuses,
            priorities: ["Highest", "High", "Medium", "Low", "Lowest"],
            issueTypes: issueTypes,
            projects: projects,
            versions: versions,
            teams: teams,
            issues: issues,
            folders: allFolders,
            pages: pages,
            pageComments: [
                DemoPageComment(id: "1200", pageID: "1000", author: priya.id,
                                body: ADF.doc([ADF.p(ADF.mention(reviewer), " Down to 3 reports since the 2.5.2 hotfix. All on iOS 17, when the timer ends in the background.")]),
                                created: hoursAgo(3), markerRef: crashMarker),
                DemoPageComment(id: "1201", pageID: "1000", author: diego.id,
                                body: ADF.doc([ADF.p("I can take it after standup. It looks like APP-111's cache work touched the same timer.")]),
                                created: hoursAgo(1), markerRef: nil, parentID: "1200"),
            ]
        )
    }
}
