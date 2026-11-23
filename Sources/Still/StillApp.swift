import AppKit
import SwiftUI

enum StillTypography {
    static let minimum = Font.system(size: 13)
}

@main struct StillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ChatStore()

    init() { UITiming.startLaunch() }

    var body: some Scene {
        Window("Still", id: "main") {
            ChatWindow(store: store)
                .font(StillTypography.minimum)
                .onAppear { delegate.store = store }
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 1040, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newChat() }.keyboardShortcut("n").disabled(!store.isRestored)
            }
            CommandMenu("Chat") {
                Button("Choose Model…") { store.chooserEvent = UUID() }
                    .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!store.isRestored)
                Button("Stop Reply") { store.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!store.replyingHere)
                Button("\(store.retryLabel) with \(store.nextSettings.label)") { store.retry() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!store.canRetry)

            }
        }
        Settings {
            BackendSettingsView(store: store)
                .font(StillTypography.minimum)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ChatStore?
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
