# JPlus

A native macOS client for Jira Cloud, built with SwiftUI. Browsing is read-only; the one write path is creating a ticket from a screenshot.

## Status

- [x] Sign in to a Jira Cloud site with an API token
- [x] Saved accounts: logins are kept in the Keychain once Jira accepts them; pick, edit or delete them on the sign-in screen
- [x] Account screen showing the signed-in user
- [x] Open any issue by key (e.g. `vpe-5555`) or pasted browse URL; recents list (7 shown, Load More / View All / Collapse)
- [x] ⌘K palette: jump to an issue or version with live suggestions and title preview
- [x] Issue detail: fields, description and comments (native ADF rendering)
- [x] Parent, subtasks and an epic's child issues on the issue detail, with progress; click to open
- [x] Images and files attached in descriptions and comments, shown inline; click to Quick Look
- [x] Linked Figma designs on the issue detail, with Open in Figma and Dev Mode
- [x] Google-style search: plain words, typo-tolerant, ranked results with snippets and "Did you mean"; JQL kept as Advanced search
- [x] Ticket details and attachments in a right-hand column (⌥⌘0 to show or hide)
- [x] Versions per project with progress, drilling into each version's issues; Hide completed toggle
- [x] New Ticket: drop/paste/choose a screenshot, create the issue, attach the image
- [x] Optional Draft with Claude: summary, description and type proposed from the screenshot
- [ ] Boards and sprints

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

The app reopens the last account you used straight away, using the name and
avatar saved at the last sign-in, and checks the token with Jira in the
background. The signed-in user is shown at the bottom of the sidebar. Switch
Account (⇧⌘A, the toolbar, or the Account screen) returns to the list without
forgetting anything. If
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

## Navigation

The top row of the sidebar has Search (⌘F) and New Ticket (⌘N) as icons.
Below are Versions (expandable, with the five lowest unreleased versions of
your project nested under it), My Issues (open issues assigned to you, the
default screen), Mentions, and your recent issues. As in ChatGPT's desktop app, the
signed-in user sits at the bottom of the sidebar: your name and site, with a
menu for Account, Settings…, opening the site in a browser, and Switch
Account…. ⌘K jumps to any issue or version.

## Mentions

Every place someone @-mentioned you, in a ticket's description or in a
comment, newest first and grouped by day. Each entry shows who mentioned you,
where, the ticket with its status, and the surrounding text with your name
highlighted; a bare "cc: @you" line shows the whole comment instead. Click to
open the ticket; right-click to open the exact comment in Jira. Jira's
`text ~ currentUser()` finds candidate issues and the app scans their
descriptions and comments for mention tags with your account ID; comments
are timed by when they were written, description mentions by when the issue
was created. Load Older Mentions pages further back.

## Search

Click the magnifying glass at the top of the sidebar, or press ⌘F.

Type plain words; misspellings and half-typed words are fine
(`downlod agrements` finds "Download terms from agreements section").
Results are ranked in the app from two sources:

- a local index of every issue title the account can see, matched with
  typo tolerance (Jira's own search has no fuzzy matching);
- Jira's word search over descriptions and comments.

Each result shows its key, project, status, assignee and age, the title with
matching words in bold, and a snippet of the description. "Did you mean"
appears when your words only matched after correcting typos. Filter by
project or to open issues; Advanced (JQL) switches to raw JQL.

The index is built in the background at launch the first time (about 10
seconds for 10,000 issues), saved in the app's container, refreshed with
changed issues every couple of minutes, and rebuilt weekly.

## Go to issue or version (⌘K)

Press ⌘K (Go menu, or the magnifying glass in the toolbar) and start typing:

- an issue key (`vpe-5636`), or just the number (`5636`) for the project of
  your most recent issue;
- a few words from a title (prefix search, so `leaderb` finds "leaderboard");
- a version name (`v1.17`), which lists matching versions first.

With nothing typed it shows your recent issues and the project's unreleased
versions. Rows show the title, type and status; the highlighted row is
previewed at the bottom with the full title, assignee and last update (or a
version's release date and progress). ↑/↓ move, Return opens, Esc closes.
Titles of issues you open are remembered per account so recents show them
instantly.

## Images, attachments and designs

Images pasted into a description or comment are drawn in place, at the width
and alignment set in Jira's editor; other files named in the text (a
spreadsheet, a PDF) appear as links or chips. Click any of them to open it in
Quick Look. Files are fetched with the account's token from
`/rest/api/3/attachment/content/{id}?redirect=false` and kept in the app's
temporary folder, so they open instantly on later visits.

Every attachment, including ones never placed in the text, is listed under
Attachments in the right-hand column, newest first, with its size and date.
Images show Jira's thumbnail (`/rest/api/3/attachment/thumbnail/{id}`); click
any row to open the file in Quick Look.

When a design is linked through Figma for Jira, a Designs section follows the
description: the design's name, whether it's Ready for dev, and buttons to
open it in Figma or in Figma's Dev Mode (right-click to copy the link).

Neither designs nor the link between an image in the text and its attachment
are in the REST API; both come from Jira's GraphQL gateway in one query
(`issueByKey` → `designs` and `attachments { mediaApiFileId }`). The designs
field needs `@optIn(to: "GraphStoreIssueAssociatedDesign")` and an
`X-Query-Context: ari:cloud:platform::site/{cloudId}` header. If the gateway
fails, the issue still loads; images then fall back to matching their alt
text, which Jira sets to the file name.

## Parents, subtasks and child issues

A sub-task or an epic's issue shows its parent at the start of the header
(type, key and title) and as a card under Parent in the right-hand column,
with the parent's status. Click either to open the parent; right-click to
open it in Jira or copy the key.

Below the description, Subtasks (Child issues on an epic) lists each child
with its type, key, title, assignee and status, plus how many are done.
Lists longer than ten start collapsed. The rows come from
`parent = KEY ORDER BY rank ASC`, which also finds an epic's children and
includes assignees; until that search returns (or if it fails) the sub-tasks
embedded in the issue are listed without assignees.

## Versions

Hide completed, left of the filter field on a version's issue list, drops
issues whose status is in Jira's Done category (Done, Won't Do) by adding
`statusCategory != Done` to the query, so paging only fetches open issues.
The choice is remembered across versions.

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
    IssueExtras.swift       Linked designs and attachment media ids (GraphQL)
    ADF.swift               Atlassian Document Format tree
  Services/
    KeychainStore.swift     Generic-password wrapper with legacy-keychain fallback
    JiraClient.swift        Stateless REST client for /rest/api/3
    SessionStore.swift      Sign-in state: restore, add/edit/delete accounts, switch
    AccountStore.swift      Saved accounts in the Keychain, migration, per-account defaults
    IssueQuery.swift        Paginated JQL result set for list views
    ScreenshotImport.swift  Drop/paste/file -> Screenshot (PNG normalisation, downscale)
    AttachmentStore.swift   Downloads attachments once, caches files and decoded images
    ClaudeClient.swift      Raw HTTP call to the Claude Messages API (structured JSON)
    ClaudeDrafter.swift     Screenshot -> ticket draft
    CommandPaletteModel.swift ⌘K search: key lookup, text search, version filter, title cache
    FuzzyMatcher.swift      Typo-tolerant word matching (edit distance, prefixes)
    MentionsModel.swift     Finds @-mentions of you in descriptions and comments
    SearchIndex.swift       Local title index: parallel build, disk cache, incremental refresh
    FuzzySearchModel.swift  Ranks local and Jira matches, snippets, "Did you mean"
    SettingsStore.swift     Claude API key in the Keychain
  Views/
    ContentView.swift       Routes on session state
    AccountPickerView.swift Sign-in screen: saved accounts with Edit and Delete
    AccountFormView.swift   Add / edit form (verifies before saving)
    HomeView.swift          Split view shell, Linear-style sidebar, navigation stack
    MyIssuesView.swift      Open issues assigned to you
    MentionsView.swift      @-mentions of you, grouped by day
    NewTicketView.swift     Screenshot well, fields, Draft with Claude, Create
    SettingsView.swift      Settings window (API key)
    FuzzySearchView.swift   Google-style search page (and the switch to JQL)
    SearchView.swift        Advanced JQL search: presets, history, results
    VersionsView.swift      Project picker + grouped versions with progress bars
    VersionDetailView.swift One version's header and issues
    IssueListView.swift     Shared issue table + footer
    IssueDetailView.swift   Issue header and parent, description, subtasks, designs, comments; fields and attachments column
    CommandPaletteView.swift ⌘K overlay: search box, suggestions, preview
    IssueBadges.swift       Status/type/priority badges, person cell, tags
    ADFView.swift           Native ADF renderer, including images and attached files
    AccountView.swift       Signed-in user card
```

## Notes

- Only Jira Cloud (Basic auth with email + API token) is supported. OAuth 2.0
  (3LO) requires a registered Atlassian app and client secret, so it's deferred.
- Jira Data Center would use Bearer personal access tokens against `/rest/api/2`;
  the client is structured so this can be added as a second credential type.
