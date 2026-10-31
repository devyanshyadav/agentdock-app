import SwiftUI

struct SidebarTabButton: View {
    let title: String
    let icon: AppIcon.Source
    let isSelected: Bool
    var badgeCount: Int? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(icon, size: 18)
                    .foregroundColor(isSelected ? AgentTheme.sidebarPrimaryForeground : AgentTheme.mutedForeground)

                Text(title)
                    .font(.agentSans(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? AgentTheme.sidebarPrimaryForeground : (isHovered ? AgentTheme.sidebarForeground : AgentTheme.sidebarForeground.opacity(0.85)))

                Spacer()

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.agentHeading(size: 10.5, weight: .semibold))
                        .foregroundColor(isSelected ? AgentTheme.sidebarPrimaryForeground : AgentTheme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected ? AgentTheme.sidebarPrimaryForeground.opacity(0.2) : AgentTheme.accent))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(sidebarBackground)
            .contentShape(RoundedRectangle(cornerRadius: AgentTheme.radiusSm))
            .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.01 : 1.0))
            .opacity(isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(PressDetectingButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                .fill(
                    LinearGradient(
                        colors: [
                            AgentTheme.sidebarPrimary,
                            AgentTheme.sidebarPrimary.opacity(0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.42), location: 0.0),
                                    .init(color: Color.white.opacity(0.12), location: 0.20),
                                    .init(color: Color.clear, location: 0.55)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                .fill(AgentTheme.sidebarAccent)
        } else {
            Color.clear
        }
    }
}
