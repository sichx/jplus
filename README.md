# JPlus

A native macOS client for Jira Cloud, built with SwiftUI. Browsing is read-only; the one write path is creating a ticket from a screenshot.

## Status

- [x] Sign in to a Jira Cloud site with an API token
- [x] Saved accounts: logins are kept in the Keychain once Jira accepts them; pick, edit or delete them on the sign-in screen
- [x] Account screen showing the signed-in user
- [x] Open any issue by key (e.g. `vpe-5555`) or pasted browse URL; recents list
- [x] Issue detail: fields, description and comments (native ADF rendering)
- [x] JQL search with presets, history, and paging
- [x] Versions per project with progress, drilling into each version's issues
- [x] New Ticket: drop/paste/choose a screenshot, create the issue, attach the image
- [x] Optional Draft with Claude: summary, description and type proposed from the screenshot
- [x] Effort estimate on each ticket: Claude sizes the work for one engineer, with range, breakdown, risks and open questions
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

## Signing in and saved accounts

1. Create an API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. Enter your site (`acme` or `acme.atlassian.net`), the email on your Atlassian
   account, and the token.

The app checks the details with `GET /rest/api/3/myself` and only saves them
once Jira accepts them. Saved logins appear on the sign-in screen: click
Sign In (or double-click the row) to use one, the pencil to edit it, the bin
to delete it, and Add Account… for another site or user. The same user on the
same site is never saved twice. When editing, leave the token blank to keep
the saved one; edits are also verified before they're saved.

The app reopens the last account you used. Switch Account (⇧⌘A, the toolbar,
or the Account screen) returns to the list without forgetting anything. If
Jira later rejects a saved token, the account is kept and marked so you can
paste a new token instead of starting over.

Each account has its own recent issues, search history and project choices.

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

## Effort estimates

Each ticket has an Effort estimate card. Press Estimate with Claude to send
the ticket's fields, description and comments to Claude (`claude-opus-5`,
JSON structured output). It returns a likely value and an optimistic to
pessimistic range in working days for one experienced engineer who knows the
codebase, plus a T-shirt size, a confidence level, a task breakdown,
assumptions, risks and open questions. Claude sees only the ticket text, not
the code. Estimates are saved per account and ticket; if the ticket is edited
afterwards the card says so, and Re-estimate runs it again. Nothing is sent
until you press the button.

## App icon

The icon source is [Design/jplus-icon.svg](Design/jplus-icon.svg): a bold black
"J" on a yellow tile, with an offset amber layer for depth. It is an
original mark, not Atlassian's logo. To regenerate the icon set after editing
the SVG (needs `resvg`, e.g. `brew install resvg`):

```bash
cd JPlus/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do
  resvg -w $s -h $s ../../../Design/jplus-icon.svg icon_${s}x${s}.png
  resvg -w $((s*2)) -h $((s*2)) ../../../Design/jplus-icon.svg icon_${s}x${s}@2x.png
done
```

## Layout

```
JPlus/
  JPlusApp.swift            App entry point, menu commands
  Models/
    JiraCredentials.swift   Site + email + token, Basic auth header, site normalization
    SavedAccount.swift      A verified login plus cached name/avatar
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
    SessionStore.swift      Sign-in state: restore, add/edit/delete accounts, switch
    AccountStore.swift      Saved accounts in the Keychain, migration, per-account defaults
    IssueQuery.swift        Paginated JQL result set for list views
    ScreenshotImport.swift  Drop/paste/file -> Screenshot (PNG normalisation, downscale)
    ClaudeClient.swift      Raw HTTP call to the Claude Messages API (structured JSON)
    ClaudeDrafter.swift     Screenshot -> ticket draft
    EffortEstimator.swift   Ticket -> effort estimate, plus the per-account estimate cache
    SettingsStore.swift     Claude API key in the Keychain
  Views/
    ContentView.swift       Routes on session state
    AccountPickerView.swift Sign-in screen: saved accounts with Edit and Delete
    AccountFormView.swift   Add / edit form (verifies before saving)
    HomeView.swift          Split view shell, sidebar, navigation stack
    NewTicketView.swift     Screenshot well, fields, Draft with Claude, Create
    SettingsView.swift      Settings window (API key)
    SearchView.swift        JQL search bar, presets, results
    VersionsView.swift      Project picker + grouped versions with progress bars
    VersionDetailView.swift One version's header and issues
    IssueListView.swift     Shared issue table + footer
    IssueDetailView.swift   Issue header, fields, description, comments
    EffortEstimateView.swift Effort estimate card on the issue detail
    IssueBadges.swift       Status/type/priority badges, person cell, tags
    ADFView.swift           Native ADF renderer
    AccountView.swift       Signed-in user card
```

## Notes

- Only Jira Cloud (Basic auth with email + API token) is supported. OAuth 2.0
  (3LO) requires a registered Atlassian app and client secret, so it's deferred.
- Jira Data Center would use Bearer personal access tokens against `/rest/api/2`;
  the client is structured so this can be added as a second credential type.
