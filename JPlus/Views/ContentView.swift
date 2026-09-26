import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch session.state {
        case .restoring:
            VStack(spacing: 16) {
                AppIconView(size: 80)
                ProgressView("Connecting to Jira…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            AccountPickerView()
        case .signedIn(let user):
            if let accountID = session.currentAccountID {
                HomeView(user: user)
                    .id(accountID)
                    .defaultAppStorage(AccountDefaults.store(for: accountID))
            }
        }
    }
}
