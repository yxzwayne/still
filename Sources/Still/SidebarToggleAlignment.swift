import AppKit
import SwiftUI

struct SidebarToggleAlignment: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarAnchor { ToolbarAnchor() }
    func updateNSView(_ view: ToolbarAnchor, context: Context) {}

    final class ToolbarAnchor: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(
                self, selector: #selector(toolbarWillAddItem(_:)),
                name: NSToolbar.willAddItemNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateToolbar()
        }

        @objc private func toolbarWillAddItem(_ notification: Notification) {
            guard let toolbar = notification.object as? NSToolbar, toolbar === window?.toolbar else { return }
            updateToolbar()
        }

        private func updateToolbar() {
            // Let SwiftUI finish installing the toolbar for this window.
            Task { @MainActor [weak self] in
                guard let toolbar = self?.window?.toolbar else { return }
                let items = toolbar.items

                // The split view puts flexible space before its toggle and divider.
                // Removing it keeps the native toggle beside the window controls.
                guard items.count >= 3, items[0].itemIdentifier == .flexibleSpace,
                      items[2] is NSTrackingSeparatorToolbarItem else { return }
                toolbar.removeItem(at: 0)
            }
        }
    }
}
