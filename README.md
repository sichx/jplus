# JPlus

A native macOS client for Jira Cloud, built with SwiftUI. Browsing is read-only; the one write path is creating a ticket from a screenshot.

## Status

- [x] Sign in to a Jira Cloud site with an API token
- [x] Credentials stored in the macOS Keychain, session restored on launch
- [x] Account screen showing the signed-in user
- [x] Open any issue by key (e.g. `vpe-5555`) or pasted browse URL; recents list
- [x] Issue detail: fields, description and comments (native ADF rendering)
- [x] JQL search with presets, history, and paging
- [x] Versions per project with progress, drilling into each version's issues
- [x] New Ticket: drop/paste/choose a screenshot, create the issue, attach the image
- [x] Optional Draft with Claude: summary, description and type proposed from the screenshot
- [ ] Boards and sprints
- [ ] Attachments and inline images

## Requirements

- macOS 15 or later
- Xcode 26 or later (project uses folder-synced groups and Swift 6)

## Running

Open `JPlus.xcodeproj` and press Run, or from the terminal:

```bash
xcodebuild -project JPlus.xcodeproj -scheme JPlus -configuration Debug build
```

The target is signed with the Apple Development identity for team `R54U6953A9`.
A stable signature matters: the token lives in the legacy Keychain, whose
access list is keyed on the app's designated requirement. Ad-hoc signing changes
that on every build and triggers a Keychain prompt each launch.

## Troubleshooting

- **App hangs at launch with no window** after a signing change: the sandbox
  container was created under the old signature. Quit the app and remove
  `~/Library/Containers/co.interactivelabs.jplus`; it is recreated on next launch.
- **"JPlus wants to use your confidential information" prompt**: choose
  *Always Allow*. It appears once per signing identity.

## Signing in

1. Create an API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. Enter your site (`acme` or `acme.atlassian.net`), the email on your Atlassian
   account, and the token.

The app verifies the token with `GET /rest/api/3/myself` before saving it.

## Creating a ticket from a screenshot

Sidebar > New Ticket (or ⌘N). Drop an image, paste one (⌘V, or ⌘⇧V for the Paste
button), or Choose… a file. Pick project and type, write a summary, and press
Create (⌘↩). The app calls `POST /rest/api/3/issue`, then uploads the image
with `POST /rest/api/3/issue/{key}/attachments`, then opens the new issue.
Descriptions are typed as plain text and converted to ADF; `## ` headings,
`- ` bullets and `1. ` numbered lines are recognised.

**Draft with Claude** is optional. Add an Anthropic API key under JPlus >
Settings (stored in the Keychain). The button sends a downscaled PNG of the
screenshot plus your notes to the Claude Messages API (`claude-opus-5`, JSON
structured output, server-side refusal fallback enabled) and fills in the
summary, description and issue type for you to edit before creating. Nothing
is sent to Anthropic unless you press that button.

## Layout

```
JPlus/
  JPlusApp.swift            App entry point, menu commands
  Models/
    JiraCredentials.swift   Site + email + token, Basic auth header, site normalization
    JiraUser.swift          /myself response
    JiraIssue.swift         Full issue (detail view), IssueKey parsing
    JiraSearch.swift        Search page + lightweight IssueSummary rows
    JiraProject.swift       Project list
    JiraVersion.swift       Versions with issue-status counts
    JiraCreate.swift        Issue types, create/attach responses, plain text -> ADF
    ADF.swift               Atlassian Document Format tree
  Services/
    KeychainStore.swift     Generic-password wrapper with legacy-keychain fallback
    JiraClient.swift        Stateless REST client for /rest/api/3
    SessionStore.swift      Observable auth state: restore / signIn / signOut
    IssueQuery.swift        Paginated JQL result set for list views
    ScreenshotImport.swift  Drop/paste/file -> Screenshot (PNG normalisation, downscale)
    ClaudeDrafter.swift     Raw HTTP call to the Claude Messages API
    SettingsStore.swift     Claude API key in the Keychain
  Views/
    ContentView.swift       Routes on session state
    SignInView.swift        Sign-in form
    HomeView.swift          Split view shell, sidebar, navigation stack
    NewTicketView.swift     Screenshot well, fields, Draft with Claude, Create
    SettingsView.swift      Settings window (API key)
    SearchView.swift        JQL search bar, presets, results
    VersionsView.swift      Project picker + grouped versions with progress bars
    VersionDetailView.swift One version's header and issues
    IssueListView.swift     Shared issue table + footer
    IssueDetailView.swift   Issue header, fields, description, comments
    IssueBadges.swift       Status/type/priority badges, person cell, tags
    ADFView.swift           Native ADF renderer
    AccountView.swift       Signed-in user card
```

## Notes

- Only Jira Cloud (Basic auth with email + API token) is supported. OAuth 2.0
  (3LO) requires a registered Atlassian app and client secret, so it's deferred.
- Jira Data Center would use Bearer personal access tokens against `/rest/api/2`;
  the client is structured so this can be added as a second credential type.
