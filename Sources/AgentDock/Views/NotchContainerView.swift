import SwiftUI

public struct NotchContainerView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var state = AgentStateManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var flashOpacity = 0.0
    @State private var flashTask: Task<Void, Never>?
    public let geometry: NotchGeometry

    public init(geometry: NotchGeometry = NotchGeometry.current()) {
        self.geometry = geometry
    }

    private var restingOpacity: Double {
        state.status == .waitingApproval ? 0.85 : state.status.isLive ? 0.45 : 0
    }

    public var body: some View {
        let visible = hasAppeared && preferences.notchEnabled && state.isIndicatorVisible
        NotchPillView(geometry: geometry, flashOpacity: flashOpacity, animatesGlow: visible)
            .scaleEffect(
                x: visible || reduceMotion ? 1 : geometry.notchWidth / geometry.totalWidth,
                y: visible || reduceMotion ? 1 : 0.02,
                anchor: .top
            )
            .opacity(visible ? 1 : 0)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12)
                    : visible ? .spring(response: 0.62, dampingFraction: 0.86)
                    : .easeInOut(duration: 0.42),
                value: visible
            )
            .onChange(of: visible) { isVisible in
                if isVisible { flash(hold: 0.45, settle: 0.70) }
                else { cancelFlash(opacity: 0) }
            }
            .onChange(of: state.status) { status in
                guard visible else { return }
                if status == .completed { flash(hold: 0.60, settle: 0.60) }
                else if status.isLive { flash(hold: 0.18, settle: 0.75) }
                else { cancelFlash(opacity: 0) }
            }
            .onChange(of: state.message) { _ in
                if visible && state.status.isLive { flash(hold: 0.18, settle: 0.75) }
            }
            .onChange(of: reduceMotion) { _ in
                cancelFlash(opacity: visible ? restingOpacity : 0)
            }
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { hasAppeared = true }
            .onDisappear { cancelFlash(opacity: 0) }
    }

    private func flash(hold: TimeInterval, settle: TimeInterval) {
        flashTask?.cancel()
        guard !reduceMotion else {
            flashOpacity = restingOpacity
            return
        }
        flashTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.16)) { flashOpacity = 1 }
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: settle)) { flashOpacity = restingOpacity }
            flashTask = nil
        }
    }

    private func cancelFlash(opacity: Double) {
        flashTask?.cancel()
        flashTask = nil
        flashOpacity = opacity
    }
}
