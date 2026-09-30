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
            CommandMenu("Go") {
                Button("Search") {
                    NotificationCenter.default.post(name: .jplusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!session.isSignedIn)
                Button("Go to Issue or Version…") {
                    NotificationCenter.default.post(name: .jplusCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!session.isSignedIn)
            }
            CommandGroup(after: .appSettings) {
                Button("Switch Account…") { session.signOut() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!session.isSignedIn)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(session)
        }
    }
}
