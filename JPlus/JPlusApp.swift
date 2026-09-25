import SwiftUI

@main
struct JPlusApp: App {
    @State private var session = SessionStore()
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(settings)
                .task { await settings.load() }
                .task { await session.restore() }
                .frame(minWidth: 480, minHeight: 360)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Ticket…") {
                    NotificationCenter.default.post(name: .jplusNewTicket, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!session.isSignedIn)
            }
            CommandGroup(after: .appSettings) {
                Button("Sign Out…") { session.signOut() }
                    .disabled(!session.isSignedIn)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
