import SwiftUI

/// Settings section with icon header + grouped card container matching Google Account layout.
public struct AgentSettingsSection<Content: View>: View {
    public let title: String
    public let icon: AppIcon.Source
    public var iconColor: Color = AgentTheme.primary
    @ViewBuilder public var content: () -> Content

    public init(
        title: String,
        icon: AppIcon.Source,
        iconColor: Color = AgentTheme.primary,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                AppIcon(icon, size: 18)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.agentHeading(size: 14, weight: .semibold))
                    .foregroundStyle(AgentTheme.foreground)
            }

            AgentGroupedCard {
                content()
            }
        }
    }
}

/// Status badge pill with dot and text
public struct AgentStatusBadge: View {
    public let text: String
    public let isReady: Bool

    public init(text: String, isReady: Bool) {
        self.text = text
        self.isReady = isReady
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isReady ? AgentTheme.success : AgentTheme.mutedForeground)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.agentSans(size: 11, weight: .semibold))
                .foregroundColor(isReady ? AgentTheme.foreground : AgentTheme.mutedForeground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(isReady ? AgentTheme.success.opacity(0.12) : AgentTheme.muted)
        )
    }
}

// MARK: - Google Account / Material 3 Grouped Row Geometry
/// Custom shape with independent corner radii for top/bottom corners (macOS 13+ compatible).
public struct UnevenRoundedCornerShape: Shape {
    public var topLeading: CGFloat
    public var topTrailing: CGFloat
    public var bottomLeading: CGFloat
    public var bottomTrailing: CGFloat

    public init(
        topLeading: CGFloat = 0,
        topTrailing: CGFloat = 0,
        bottomLeading: CGFloat = 0,
        bottomTrailing: CGFloat = 0
    ) {
        self.topLeading = topLeading
        self.topTrailing = topTrailing
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        let tr = max(0, min(min(topTrailing, h / 2), w / 2))
        let tl = max(0, min(min(topLeading, h / 2), w / 2))
        let bl = max(0, min(min(bottomLeading, h / 2), w / 2))
        let br = max(0, min(min(bottomTrailing, h / 2), w / 2))

        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: w - tr, y: tr),
                radius: tr,
                startAngle: Angle(degrees: -90),
                endAngle: Angle(degrees: 0),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: w, y: 0))
        }

        path.addLine(to: CGPoint(x: w, y: h - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: w - br, y: h - br),
                radius: br,
                startAngle: Angle(degrees: 0),
                endAngle: Angle(degrees: 90),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: w, y: h))
        }

        path.addLine(to: CGPoint(x: bl, y: h))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: bl, y: h - bl),
                radius: bl,
                startAngle: Angle(degrees: 90),
                endAngle: Angle(degrees: 180),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: 0, y: h))
        }

        path.addLine(to: CGPoint(x: 0, y: tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: tl, y: tl),
                radius: tl,
                startAngle: Angle(degrees: 180),
                endAngle: Angle(degrees: 270),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: 0, y: 0))
        }

        path.closeSubpath()
        return path
    }
}

/// Identifies the relative vertical position of a row inside a Google Account-style connected group.
public enum GroupedRowPosition {
    case single
    case top
    case middle
    case bottom

    public var shape: UnevenRoundedCornerShape {
        switch self {
        case .single:
            return UnevenRoundedCornerShape(topLeading: 16, topTrailing: 16, bottomLeading: 16, bottomTrailing: 16)
        case .top:
            return UnevenRoundedCornerShape(topLeading: 16, topTrailing: 16, bottomLeading: 4, bottomTrailing: 4)
        case .middle:
            return UnevenRoundedCornerShape(topLeading: 4, topTrailing: 4, bottomLeading: 4, bottomTrailing: 4)
        case .bottom:
            return UnevenRoundedCornerShape(topLeading: 4, topTrailing: 4, bottomLeading: 16, bottomTrailing: 16)
        }
    }
}

/// Container that groups connected row tiles with a 2.5px gap showing the page background.
public struct AgentGroupedCard<Content: View>: View {
    public var spacing: CGFloat = 2.5
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 2.5, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        VStack(spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Authentic Google Account-style connected tile with outer 16pt curves and inner 4pt micro-radii.
public struct AgentGroupedRow<Content: View>: View {
    public var position: GroupedRowPosition = .middle
    public var paddingVertical: CGFloat = 13
    public var paddingHorizontal: CGFloat = 16
    @ViewBuilder public var content: () -> Content

    public init(
        position: GroupedRowPosition = .middle,
        paddingVertical: CGFloat = 13,
        paddingHorizontal: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.position = position
        self.paddingVertical = paddingVertical
        self.paddingHorizontal = paddingHorizontal
        self.content = content
    }

    public var body: some View {
        let shape = position.shape
        content()
            .padding(.horizontal, paddingHorizontal)
            .padding(.vertical, paddingVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape
                    .fill(AgentTheme.card)
            )
            .clipShape(shape)
            .overlay(
                shape
                    .stroke(AgentTheme.border.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}
