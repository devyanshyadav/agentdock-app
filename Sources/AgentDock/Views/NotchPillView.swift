import SwiftUI

// MARK: - Hardware Notch Silhouette Shape
/// Concave fillets at the top screen edge and convex rounded bottom corners,
/// seamlessly enclosing the physical MacBook notch and bezel.
public struct MacNotchShape: Shape {
    public var topFilletRadius: CGFloat
    public var bottomCornerRadius: CGFloat
    public var chinWidth: CGFloat
    public var wingHeight: CGFloat
    public var style: NotchStyle

    public init(topFilletRadius: CGFloat = 12, bottomCornerRadius: CGFloat = 14,
                chinWidth: CGFloat = 180, wingHeight: CGFloat = 40, style: NotchStyle = .stepped) {
        self.topFilletRadius = topFilletRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.chinWidth = chinWidth
        self.wingHeight = wingHeight
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        var path = outline(in: rect)
        path.closeSubpath()
        return path
    }

    /// The visible outline stays open where the notch meets the screen edge.
    func outline(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let top = topFilletRadius
        let wing = style == .rounded ? h : min(wingHeight, h)
        let corner = min(bottomCornerRadius, wing / 2)
        let leftChin = (w - chinWidth) / 2
        let rightChin = w - leftChin
        let step = min(bottomCornerRadius, (h - wing) / 2)

        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(to: CGPoint(x: top, y: top),
                      control1: CGPoint(x: top / 2, y: 0),
                      control2: CGPoint(x: top, y: top / 2))
        path.addLine(to: CGPoint(x: top, y: wing - corner))
        path.addQuadCurve(to: CGPoint(x: top + corner, y: wing),
                          control: CGPoint(x: top, y: wing))
        path.addLine(to: CGPoint(x: leftChin - step, y: wing))
        // Only the central status area descends below the compact icon wings.
        path.addCurve(to: CGPoint(x: leftChin + step, y: h),
                      control1: CGPoint(x: leftChin, y: wing),
                      control2: CGPoint(x: leftChin, y: h))
        path.addLine(to: CGPoint(x: rightChin - step, y: h))
        path.addCurve(to: CGPoint(x: rightChin + step, y: wing),
                      control1: CGPoint(x: rightChin, y: h),
                      control2: CGPoint(x: rightChin, y: wing))
        path.addLine(to: CGPoint(x: w - top - corner, y: wing))
        path.addQuadCurve(to: CGPoint(x: w - top, y: wing - corner),
                          control: CGPoint(x: w - top, y: wing))
        path.addLine(to: CGPoint(x: w - top, y: top))
        path.addCurve(to: CGPoint(x: w, y: 0),
                      control1: CGPoint(x: w - top, y: top / 2),
                      control2: CGPoint(x: w - top / 2, y: 0))
        return path
    }
}

// MARK: - Open Contour Outline Shape for the Hardware Notch
/// Follows the open visible outline (ears, transitions, and bottom chin) without closing the top edge,
/// ensuring dynamic resolution and exact sub-pixel tracking during notch motion and scaling.
public struct MacNotchOutlineShape: Shape {
    public var topFilletRadius: CGFloat
    public var bottomCornerRadius: CGFloat
    public var chinWidth: CGFloat
    public var wingHeight: CGFloat
    public var style: NotchStyle

    public init(topFilletRadius: CGFloat = 12, bottomCornerRadius: CGFloat = 14,
                chinWidth: CGFloat = 180, wingHeight: CGFloat = 40, style: NotchStyle = .stepped) {
        self.topFilletRadius = topFilletRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.chinWidth = chinWidth
        self.wingHeight = wingHeight
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        MacNotchShape(
            topFilletRadius: topFilletRadius,
            bottomCornerRadius: bottomCornerRadius,
            chinWidth: chinWidth,
            wingHeight: wingHeight,
            style: style
        ).outline(in: rect)
    }
}

// MARK: - Notch Pill View
/// Hardware-preserving notch UI using the app's real agent icons, status, and loaders.
public struct NotchPillView: View {
    public let geometry: NotchGeometry
    public let flashOpacity: Double
    private let animatesGlow: Bool
    @ObservedObject private var state = AgentStateManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    private let previewText: String?

    private var message: String { previewText ?? state.message }
    private var status: AgentStatus { previewText == nil ? state.status : .working }
    private var isVisible: Bool { previewText != nil || state.isIndicatorVisible }
    private var agent: AgentKind { previewText == nil ? state.activeAgent : .claude }

    public init(geometry: NotchGeometry = NotchGeometry.current(), flashOpacity: Double = 0.0, animatesGlow: Bool = false) {
        self.geometry = geometry
        self.flashOpacity = flashOpacity
        self.animatesGlow = animatesGlow
        self.previewText = nil
    }

    init(geometry: NotchGeometry, previewText: String, flashOpacity: Double = 0.0) {
        self.geometry = geometry
        self.flashOpacity = flashOpacity
        self.animatesGlow = false
        self.previewText = previewText
    }

    public var body: some View {
        if previewText != nil {
            notchContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sample notch activity: " + NotchActivityText.displayText(message))
        } else {
            focusButton
                .accessibilityAction(named: Text("Reset notch activity")) { state.resetActivity() }
                .overlay(alignment: .topTrailing) { resetButton }
                .onHover { isHovered = $0 }
                .onChange(of: state.isIndicatorVisible) { if !$0 { isHovered = false } }
        }
    }

    private var focusButton: some View {
        Button {
            AgentFocusCoordinator.shared.focusActiveAgent()
        } label: {
            notchContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.activeAgent.displayName
            + (state.modelName.isEmpty ? "" : ", " + ModelName.display(state.modelName, agent: state.activeAgent))
            + (state.message.isEmpty ? "" : ", " + NotchActivityText.displayText(state.message)))
        .accessibilityHint("Open the current agent")
    }

    private var notchContent: some View {
        ZStack(alignment: .top) {
            // 1. Pure black notch enclosure blending seamlessly with hardware notch & top bezel
            notchShape
                .fill(Color.black)

            // 2. Bottom Primary Flash (Luminous edge glow perfectly synced with notch contour)
            bottomPrimaryFlash
                .opacity(flashOpacity)

            // 3. Hardware-aware layout
            HStack(alignment: .top, spacing: 0) {
                // Left Ear: Provider Logo
                VStack {
                    Spacer(minLength: 0)
                    ProviderIcon(provider: agent.rawValue, fallbackSymbol: agent.symbolIcon, size: geometry.providerIconSize)
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.earWidth)
                .frame(height: geometry.wingHeight)
                .padding(.leading, geometry.topFilletRadius)

                // Reserve the hardware camera area independently of the text row.
                Color.clear.frame(width: geometry.notchWidth, height: geometry.wingHeight)
                    .accessibilityHidden(true)

                // Right Ear: Real Loader / Status Indicator
                VStack {
                    Spacer(minLength: 0)
                    if status.isLive || status == .completed || status == .error {
                        DotMatrixLoader(activity: NotchActivityText.displayText(message),
                                        size: geometry.providerIconSize, status: status, isVisible: isVisible)
                            .opacity(isHovered ? 0 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.earWidth)
                .frame(height: geometry.wingHeight)
                .padding(.trailing, geometry.topFilletRadius)
            }

            if geometry.showsBottomText {
                activityText
                    .padding(.top, geometry.textTopInset)
            }
        }
        .frame(width: geometry.totalWidth, height: geometry.totalHeight, alignment: .top)
        .contentShape(notchShape)
    }

    private var activityText: some View {
        let slot = geometry.textAreaWidth - 2 * geometry.bottomCornerRadius
        return Group {
            if status == .waitingApproval {
                NotchActivityText(text: message.isEmpty ? "Needs approval" : NotchActivityText.displayText(message),
                                  width: slot, color: .yellow, isVisible: isVisible)
            } else if !message.isEmpty {
                NotchActivityText(text: NotchActivityText.displayText(message),
                                  width: slot, isVisible: isVisible)
            } else {
                let model = ModelName.clipped(ModelName.display(state.modelName, agent: agent), limit: 16)
                NotchActivityText(text: agent.displayName + (model.isEmpty ? "" : " · " + model),
                                  width: slot, isVisible: isVisible)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: slot, height: geometry.chinHeight)
        .padding(.horizontal, geometry.bottomCornerRadius)
        .padding(.bottom, geometry.bottomPadding)
    }

    private var notchShape: MacNotchShape {
        MacNotchShape(topFilletRadius: geometry.topFilletRadius, bottomCornerRadius: geometry.bottomCornerRadius,
                      chinWidth: geometry.notchWidth, wingHeight: geometry.wingHeight, style: geometry.style)
    }

    private var resetButton: some View {
        Button {
            state.resetActivity()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.08), in: Circle())
                .frame(width: geometry.earWidth, height: geometry.wingHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reset notch activity")
        .accessibilityLabel("Reset notch activity")
        .padding(.trailing, geometry.topFilletRadius)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
    }

    private var notchOutline: MacNotchOutlineShape {
        MacNotchOutlineShape(
            topFilletRadius: geometry.topFilletRadius,
            bottomCornerRadius: geometry.bottomCornerRadius,
            chinWidth: geometry.notchWidth,
            wingHeight: geometry.wingHeight,
            style: geometry.style
        )
    }

    private var bottomPrimaryFlash: some View {
        Group {
            if animatesGlow && isVisible && status.isLive && flashOpacity > 0 && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let waveX = 0.5 + 0.45 * CGFloat(sin(t * 2.2))
                    flashContour(waveX: waveX)
                }
            } else {
                flashContour(waveX: 0.5)
            }
        }
        .mask(alignment: .bottom) {
            VStack(spacing: 0) {
                Color.clear
                LinearGradient(
                    colors: [.clear, .white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(geometry.totalHeight - geometry.wingHeight + 12, 24))
            }
        }
        .frame(width: geometry.totalWidth, height: geometry.totalHeight, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private func flashContour(waveX: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // 1. Soft radiant aura bloom directly following the wave along the bottom chin contour
            notchOutline
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            AgentTheme.primary.opacity(0.30),
                            AgentTheme.primary.opacity(0.85),
                            AgentTheme.primary.opacity(0.85),
                            AgentTheme.primary.opacity(0.30),
                            Color.clear
                        ],
                        startPoint: UnitPoint(x: waveX - 0.40, y: 0.5),
                        endPoint: UnitPoint(x: waveX + 0.40, y: 0.5)
                    ),
                    lineWidth: 3.5
                )
                .blur(radius: 4)

            // 2. Continuous ambient contour foundation
            notchOutline
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            AgentTheme.primary.opacity(0.20),
                            AgentTheme.primary.opacity(0.60),
                            AgentTheme.primary.opacity(0.60),
                            AgentTheme.primary.opacity(0.20),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.2
                )

            // 3. Crisp, moving specular wave traveling along the chin contour and corner fillets
            notchOutline
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            AgentTheme.primary.opacity(0.25),
                            AgentTheme.primary,
                            Color.white.opacity(0.95),
                            AgentTheme.primary,
                            AgentTheme.primary.opacity(0.25),
                            Color.clear
                        ],
                        startPoint: UnitPoint(x: waveX - 0.28, y: 0.5),
                        endPoint: UnitPoint(x: waveX + 0.28, y: 0.5)
                    ),
                    lineWidth: 1.6
                )
                .shadow(color: AgentTheme.primary.opacity(0.85), radius: 3, x: 0, y: 1)
        }
    }
}
