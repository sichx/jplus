import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch session.state {
        case .restoring:
            // Only lasts while saved accounts are read from the Keychain.
            Color.clear
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
