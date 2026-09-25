import SwiftUI

struct AccountView: View {
    @Environment(SessionStore.self) private var session
    let user: JiraUser

    var body: some View {
        VStack(spacing: 20) {
            AvatarView(user: user, size: 72)

            VStack(spacing: 4) {
                Text(user.displayName)
                    .font(.title2.weight(.semibold))
                if let email = user.emailAddress {
                    Text(email).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow("Site", session.client?.credentials.siteHost ?? "—")
                detailRow("Account ID", user.accountId)
                detailRow("Time zone", user.timeZone ?? "—")
                detailRow("Status", (user.active ?? true) ? "Active" : "Inactive")
            }
            .font(.callout)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Account")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
