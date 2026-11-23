import SwiftUI

enum InteractionMotion {
    static let symbol = Animation.easeInOut(duration: 0.12)
    static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
}

enum InteractionMetrics {
    static let controlSize: CGFloat = 28
    static let cornerRadius: CGFloat = 6
}

struct HoverHighlight<Background: Shape>: ViewModifier {
    let shape: Background
    var tint: Color = .primary
    var isPressed = false
    var isSelected = false
    var feedbackAnimation: Animation? = nil

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                InteractionFill(shape: shape, tint: tint, isPressed: isPressed,
                                isSelected: isSelected, isHovered: isHovered,
                                feedbackAnimation: feedbackAnimation)
            }
            .contentShape(.interaction, shape)
            .onHover { isHovered = $0 }
    }
}

struct InteractionFill<Background: Shape>: View {
    let shape: Background
    let tint: Color
    let isPressed: Bool
    let isSelected: Bool
    let isHovered: Bool
    let feedbackAnimation: Animation?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    private var opacity: Double {
        if !isEnabled { return isSelected ? 0.10 : 0 }
        if isPressed { return contrast == .increased ? 0.25 : 0.16 }
        if isSelected { return contrast == .increased ? 0.22 : 0.14 }
        if isHovered { return contrast == .increased ? 0.16 : 0.09 }
        return 0
    }

    var body: some View {
        let fill = shape.fill(tint)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        if let feedbackAnimation {
            fill.animation(feedbackAnimation, value: opacity)
        } else {
            fill
        }
    }
}

struct HoverButtonStyle<Background: Shape>: ButtonStyle {
    let shape: Background
    var tint: Color = .primary
    var fill: Color = .clear
    var isSelected = false
    var feedbackAnimation: Animation? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverHighlight(shape: shape, tint: tint, isPressed: configuration.isPressed,
                                     isSelected: isSelected, feedbackAnimation: feedbackAnimation))
            .background(fill, in: shape)
            .contentShape(.focusEffect, shape)
    }
}

extension HoverButtonStyle where Background == RoundedRectangle {
    init() {
        self.init(shape: RoundedRectangle(cornerRadius: InteractionMetrics.cornerRadius))
    }
}
