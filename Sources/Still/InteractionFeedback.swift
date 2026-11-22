import SwiftUI

enum InteractionMotion {
    static let highlight = Animation.easeInOut(duration: 0.10)
    static let symbol = Animation.easeInOut(duration: 0.12)
    static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
}

struct HoverHighlight<Background: Shape>: ViewModifier {
    let shape: Background
    var tint: Color = .primary
    var isPressed = false
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var opacity: Double {
        guard isEnabled, !isSelected else { return 0 }
        if isPressed { return 0.16 }
        return isHovered ? 0.09 : 0
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(tint)
                    .opacity(opacity)
                    .animation(InteractionMotion.highlight, value: opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
    }
}

struct HoverButtonStyle<Background: Shape>: ButtonStyle {
    let shape: Background
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(shape)
            .modifier(HoverHighlight(shape: shape, tint: tint, isPressed: configuration.isPressed))
    }
}

extension HoverButtonStyle where Background == RoundedRectangle {
    init() {
        self.init(shape: RoundedRectangle(cornerRadius: 6))
    }
}
