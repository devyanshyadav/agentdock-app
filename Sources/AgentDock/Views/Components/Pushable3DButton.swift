import SwiftUI
import AppKit

// MARK: - 3D Pushable Control Variants
public enum Agent3DVariant {
    case primary
    case secondary
    case ghost
    case warning

    public var faceColors: [Color] {
        switch self {
        case .primary:
            return [AgentTheme.primary, AgentTheme.primary.opacity(0.85)]
        case .secondary:
            return [AgentTheme.card, AgentTheme.muted]
        case .ghost:
            return [AgentTheme.muted.opacity(0.7), AgentTheme.muted.opacity(0.3)]
        case .warning:
            return AgentTheme.warningGradient
        }
    }

    public var defaultForegroundColor: Color {
        switch self {
        case .primary:
            return AgentTheme.primaryForeground
        case .secondary, .ghost, .warning:
            return AgentTheme.foreground
        }
    }
}

// MARK: - Tactile Button with Shiny Specular Outline & Subtle Touch Feedback
public struct Pushable3DButton<Content: View>: View {
    private let action: () -> Void
    private let content: Content
    private var baseGradient: [Color]
    private var foregroundColor: Color
    private var cornerRadius: CGFloat

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    public init(
        variant: Agent3DVariant,
        cornerRadius: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.action = action
        self.content = content()
        self.baseGradient = variant.faceColors
        self.foregroundColor = variant.defaultForegroundColor
        self.cornerRadius = cornerRadius ?? AgentTheme.radiusSm
    }

    public var body: some View {
        Button {
            action()
        } label: {
            content
                .foregroundColor(foregroundColor)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: baseGradient,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            // Top sheen
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.15),
                                            Color.clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        )
                        .overlay(
                            // Shiny top rim highlight stroke
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(
                                    LinearGradient(
                                        stops: [
                                            .init(color: Color.white.opacity(0.48), location: 0.0),
                                            .init(color: Color.white.opacity(0.16), location: 0.22),
                                            .init(color: Color.clear, location: 0.60)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .overlay(
                            // Subtle perimeter stroke
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(AgentTheme.border.opacity(0.4), lineWidth: 0.5)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.015 : 1.0))
                .opacity(isPressed ? 0.88 : (isHovered ? 0.96 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(PressDetectingButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Circular / Squircle Tactile Button
public struct CirclePushable3DButton<Content: View>: View {
    private let action: () -> Void
    private let content: Content
    private var baseGradient: [Color]
    private var foregroundColor: Color
    private var size: CGFloat
    private var cornerRadius: CGFloat

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    public init(
        size: CGFloat = 34,
        variant: Agent3DVariant = .secondary,
        cornerRadius: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.action = action
        self.content = content()
        self.baseGradient = variant.faceColors
        self.foregroundColor = variant.defaultForegroundColor
        self.size = size
        self.cornerRadius = cornerRadius ?? AgentTheme.radiusForButton(size: size)
    }

    public var body: some View {
        Button {
            action()
        } label: {
            content
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: baseGradient,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.15), Color.clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(
                                    LinearGradient(
                                        stops: [
                                            .init(color: Color.white.opacity(0.48), location: 0.0),
                                            .init(color: Color.white.opacity(0.16), location: 0.22),
                                            .init(color: Color.clear, location: 0.60)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(AgentTheme.border.opacity(0.4), lineWidth: 0.5)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.025 : 1.0))
                .opacity(isPressed ? 0.88 : (isHovered ? 0.96 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(PressDetectingButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Press Detection Helper
public struct PressDetectingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    public init(isPressed: Binding<Bool>) {
        self._isPressed = isPressed
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in
                withAnimation(.easeOut(duration: 0.12)) {
                    isPressed = pressed
                }
            }
    }
}
