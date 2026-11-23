import AppKit
import SwiftUI

struct ReasoningDisclosure: View {
    let reasoning: String
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hovered = false
    @State private var showingFullReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onToggle()
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("Reasoning")
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.trailing, 6)
                .frame(minHeight: InteractionMetrics.controlSize)
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                ReasoningPreview(reasoning: reasoning) { showingFullReasoning = true }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : InteractionMotion.reveal, value: expanded)
        .sheet(isPresented: $showingFullReasoning) {
            ReasoningSheet(reasoning: reasoning)
        }
    }
}

private struct ReasoningSheet: View {
    let reasoning: String
    private static let textInset: CGFloat = 20
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Reasoning").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Text("Done")
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                }
                .buttonStyle(HoverButtonStyle(shape: Capsule(), fill: .primary.opacity(0.07),
                                             feedbackAnimation: InteractionMotion.symbol))
                .keyboardShortcut(.cancelAction)
            }
            // Match the main window's toolbar button inset.
            .padding([.top, .trailing], 8)
            .padding(.leading, Self.textInset)
            ScrollView {
                Text(reasoning)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding([.leading, .trailing, .bottom], Self.textInset)
        }
        .frame(width: 560, height: 400)
        .background(SheetOutsideClickHandler { dismiss() })
    }
}

private struct SheetOutsideClickHandler: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        // Intercept backdrop clicks before AppKit blocks them at the modal window.
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak view, weak coordinator] event in
            guard let sheet = view?.window, let parent = sheet.sheetParent else { return event }
            if let window = event.window, window !== parent, window !== sheet { return event }
            let point = event.locationInWindow
            let location = event.window?.convertPoint(toScreen: point) ?? point
            guard parent.frame.contains(location), !sheet.frame.contains(location) else { return event }
            coordinator?.onOutsideClick?()
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var onOutsideClick: (() -> Void)?
        var monitor: Any?
    }
}

private struct ReasoningPreview: View {
    let reasoning: String
    let readFullReasoning: () -> Void
    private static let lineLimit = 6
    @State private var previewHeight: CGFloat = 0
    @State private var extendedHeight: CGFloat = 0

    private var hasMoreReasoning: Bool { previewHeight > 0 && extendedHeight > previewHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewText(lineLimit: Self.lineLimit)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                .background(alignment: .topLeading) {
                    // A seventh line is enough to detect overflow at the actual rendered width.
                    previewText(lineLimit: Self.lineLimit + 1)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { extendedHeight = $0 }
                }

            if hasMoreReasoning {
                Button(action: readFullReasoning) {
                    Text("Read full reasoning")
                        .foregroundStyle(Color(nsColor: .linkColor))
                        .padding(.horizontal, 8)
                        .frame(minHeight: InteractionMetrics.controlSize)
                }
                .buttonStyle(HoverButtonStyle(shape: Capsule(), tint: Color(nsColor: .linkColor),
                                             feedbackAnimation: InteractionMotion.symbol))
                .transition(.opacity.animation(InteractionMotion.symbol))
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1).allowsHitTesting(false)
        }
    }

    private func previewText(lineLimit: Int) -> some View {
        Text(reasoning)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
