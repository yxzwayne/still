import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusID: UUID?
    let onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = SubmitTextView()
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = SubmitTextView.inputFont; editor.textColor = .labelColor
        editor.drawsBackground = false
        let lineHeight = editor.layoutManager!.defaultLineHeight(for: SubmitTextView.inputFont)
        editor.textContainerInset = NSSize(width: 3, height: (SubmitTextView.singleLineHeight - lineHeight) / 2)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.onWidthChange = { [weak coordinator = context.coordinator] editor in coordinator?.resize(editor) }
        editor.delegate = context.coordinator; editor.submit = onSubmit
        editor.setAccessibilityLabel("Message")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        editor.submit = onSubmit
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.needsDisplay = true
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.resize(editor)
        }
        if let focusID, coordinator.lastFocus != focusID {
            coordinator.lastFocus = focusID
            editor.requestFocus()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocus: UUID?
        private var latestHeight: CGFloat?
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; resize(editor)
        }
        func resize(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            var bottom = manager.usedRect(for: container).maxY
            if manager.extraLineFragmentTextContainer === container {
                bottom = max(bottom, manager.extraLineFragmentRect.maxY)
            }
            let value = min(150, max(SubmitTextView.singleLineHeight, ceil(bottom + 2 * editor.textContainerInset.height)))
            guard latestHeight != value else { return }
            latestHeight = value
            DispatchQueue.main.async { [weak self] in
                guard let self, latestHeight == value, parent.height != value else { return }
                parent.height = value
            }
        }
    }
}

final class SubmitTextView: NSTextView {
    static let singleLineHeight: CGFloat = 28
    static let inputFont = NSFont.systemFont(ofSize: 15)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let container = textContainer else { return }
        let origin = textContainerOrigin
        let start = NSPoint(x: origin.x + container.lineFragmentPadding, y: origin.y)
        ("Message…" as NSString).draw(at: start, withAttributes: [
            .font: Self.inputFont, .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    var submit: (() -> Void)?
    var onWidthChange: ((NSTextView) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if oldWidth != newSize.width { onWidthChange?(self) }
    }

    private var awaitingFocus = false

    func requestFocus() {
        awaitingFocus = true
        DispatchQueue.main.async { [weak self] in self?.focusWhenKey() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let notifications = NotificationCenter.default
        notifications.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else { return }
        notifications.addObserver(self, selector: #selector(focusWhenKey), name: NSWindow.didBecomeKeyNotification, object: window)
        focusWhenKey()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder, window?.isKeyWindow == true { UITiming.markComposerReady() }
        return becameFirstResponder
    }

    @objc private func focusWhenKey() {
        guard let window, window.isKeyWindow else { return }
        if awaitingFocus { awaitingFocus = !window.makeFirstResponder(self) }
        if window.firstResponder === self { UITiming.markComposerReady() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            submit?()
        } else { super.keyDown(with: event) }
    }
}
