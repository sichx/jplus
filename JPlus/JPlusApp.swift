import SwiftUI

@main
struct JPlusApp: App {
    @State private var session = SessionStore()
    @State private var settings = SettingsStore()
    @State private var github = GitHubStore()
    @AppStorage(TextSize.storageKey) private var textSizeStep = TextSize.standardStep
    @AppStorage(AppFont.storageKey) private var appFont = AppFont.standard
    @AppStorage(SidebarSection.hiddenStorageKey) private var hiddenSidebarRaw = ""
    #if os(macOS)
    @State private var updater = AppUpdater()
    #endif

    init() {
        AppFont.registerBundledFonts()
        #if os(macOS)
        TextSize.installEqualsShortcut()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(settings)
                .environment(github)
                .textSize(step: textSizeStep, font: appFont)
                .task { await settings.load() }
                .task { await session.restore() }
                .task(id: session.currentAccountID) { await github.load(for: session.currentAccountID) }
                .appSettings()
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 360)
                .background(WindowFrameAutosave(name: "JPlusMainWindow"))
                .environment(updater)
                #endif
        }
        .commands {
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            #endif
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
            CommandGroup(after: .toolbar) {
                Divider()
                Menu("Show in Sidebar") {
                    ForEach(SidebarSection.allCases) { section in
                        Toggle(section.title, isOn: sidebarBinding(for: section))
                    }
                }
                Divider()
                Button("Make Text Bigger") { textSizeStep = TextSize.clamped(textSizeStep + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(textSizeStep >= TextSize.largestStep)
                Button("Make Text Smaller") { textSizeStep = TextSize.clamped(textSizeStep - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(textSizeStep <= 0)
                Button("Make Text Standard Size") { textSizeStep = TextSize.standardStep }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(textSizeStep == TextSize.standardStep)
            }
            CommandGroup(after: .appSettings) {
                Button("Switch Account…") { session.switchAccount() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!session.isSignedIn)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(settings)
                .environment(session)
                .environment(updater)
                .environment(github)

        }
        #endif
    }

    /// Checked while `section` shows in the sidebar.
    private func sidebarBinding(for section: SidebarSection) -> Binding<Bool> {
        Binding {
            !SidebarSection.hidden(in: hiddenSidebarRaw).contains(section)
        } set: { isShown in
            hiddenSidebarRaw = SidebarSection.raw(hiddenSidebarRaw, showing: section, isShown)
        }
    }
}
