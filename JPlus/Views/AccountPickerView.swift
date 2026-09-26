import SwiftUI

/// Sign-in screen: pick a saved account, or add, edit or delete one.
/// Falls back to the plain sign-in form when nothing is saved yet.
struct AccountPickerView: View {
    @Environment(SessionStore.self) private var session

    @State private var signingInID: UUID?
    @State private var rowErrors: [UUID: String] = [:]
    @State private var editing: SavedAccount?
    @State private var isAdding = false
    @State private var pendingDelete: SavedAccount?

    var body: some View {
        Group {
            if session.accounts.accounts.isEmpty {
                ScrollView {
                    AccountFormView(mode: .firstAccount)
                        .frame(maxWidth: .infinity)
                }
            } else {
                picker
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { account in
            AccountFormView(mode: .edit(account))
                .environment(session)
        }
        .sheet(isPresented: $isAdding) {
            AccountFormView(mode: .add)
                .environment(session)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.label ?? "account")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { account in
            Button("Delete", role: .destructive) { delete(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Removes \(account.credentials.email) on \(account.credentials.siteHost) and its API token from this Mac. The token stays valid at Atlassian until you revoke it there.")
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    AppIconView(size: 80)
                    Text("Choose an Account")
                        .font(.title.weight(.semibold))
                    Text("Pick a saved Jira login. Nothing needs to be re-entered.")
                        .foregroundStyle(.secondary)
                }

                if let notice = session.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    let accounts = session.accounts.sortedAccounts
                    ForEach(accounts) { account in
                        AccountRow(
                            account: account,
                            isSigningIn: signingInID == account.id,
                            isBusy: signingInID != nil,
                            error: rowErrors[account.id],
                            onSignIn: { signIn(account) },
                            onEdit: { editing = account },
                            onDelete: { pendingDelete = account }
                        )
                        if account.id != accounts.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 560)

                Button("Add Account…", systemImage: "plus") { isAdding = true }
                    .disabled(signingInID != nil)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func signIn(_ account: SavedAccount) {
        guard signingInID == nil else { return }
        if account.tokenRejected {
            editing = account
            return
        }
        signingInID = account.id
        rowErrors[account.id] = nil
        Task {
            defer { signingInID = nil }
            do {
                try await session.signIn(to: account)
            } catch {
                rowErrors[account.id] = error.localizedDescription
            }
        }
    }

    private func delete(_ account: SavedAccount) {
        Task {
            do {
                try await session.deleteAccount(id: account.id)
                rowErrors[account.id] = nil
            } catch {
                rowErrors[account.id] = error.localizedDescription
            }
        }
    }
}

private struct AccountRow: View {
    let account: SavedAccount
    let isSigningIn: Bool
    let isBusy: Bool
    let error: String?
    let onSignIn: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: account.avatarURL, initials: account.initials, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(account.label).fontWeight(.medium)
                Text("\(account.credentials.email) · \(account.credentials.siteHost)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.tokenRejected {
                    Label("API token no longer works. Edit to replace it.", systemImage: "key.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let lastUsed = account.lastUsedAt {
                    Text("Last used \(lastUsed.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if isSigningIn {
                ProgressView().controlSize(.small)
                    .frame(width: 70)
            } else {
                Button(account.tokenRejected ? "Fix…" : "Sign In", action: onSignIn)
                    .disabled(isBusy)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit site, email or API token")
            .disabled(isBusy)
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved account")
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if !isBusy { onSignIn() } }
        .contextMenu {
            Button(account.tokenRejected ? "Fix Token…" : "Sign In", action: onSignIn)
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
    }
}
