import AppKit
import SwiftUI

@main struct StillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ChatStore()

    init() { UITiming.startLaunch() }

    var body: some Scene {
        Window("Still", id: "main") {
            ChatWindow(store: store)
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
                Button("Stop Reply") { store.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!store.replyingHere)
                Button("Retry Last Reply") { store.retry() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.busy || store.selected?.messages.last?.role != .assistant)
                Divider()
                Button("Unload Local Model") { store.runtime.unload() }.disabled(store.busy)
            }
        }
        Settings { BackendSettingsView(store: store) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ChatStore?
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
