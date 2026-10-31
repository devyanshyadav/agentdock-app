import SwiftUI

/// Native dot-matrix patterns share one canvas and tick only while work is active.
struct DotMatrixLoader: View {
    enum Pattern: CaseIterable {
        case diagonalSweep, wovenStrands, spiralInward, fillAndDrain, equalizer, narrowHelix, liquidHex

        private static let hexRowCounts = [3, 4, 5, 4, 3]
        private static let blinkOpacities = [0.38, 1, 0.38, 1]
        private static let spiralOrder = [0, 1, 2, 3, 4, 15, 16, 17, 18, 5, 14, 23, 24, 19, 6, 13, 22, 21, 20, 7, 12, 11, 10, 9, 8]
        private static let spiralFrames: [(time: Double, opacity: Double)] = [
            (0, 0.08), (0.08, 1), (0.16, 0.644), (0.24, 0.442), (0.32, 0.24), (0.40, 0.12), (1, 0.08)
        ]

        func columns(in row: Int) -> Int { self == .liquidHex ? Self.hexRowCounts[row] : 5 }

        func opacity(row: Int, col: Int, elapsed: Double, reducedMotion: Bool) -> Double {
            switch self {
            case .diagonalSweep:
                let slice = row + 4 - col
                let parity = slice % 2
                if reducedMotion { return parity == 0 ? 0.88 : 0.14 }
                let delay = (Double(slice) / 8 * 0.2 + Double(parity) * 0.5) * 1.5
                guard elapsed >= delay else { return 0.24 }
                let phase = (elapsed - delay).truncatingRemainder(dividingBy: 1.5) / 1.5
                // CSS linear keyframes: 0% .08, 14% 1, 30% .12, 100% .08.
                if phase < 0.14 { return 0.08 + phase / 0.14 * 0.92 }
                if phase < 0.30 { return 1 - (phase - 0.14) / 0.16 * 0.88 }
                return 0.12 - (phase - 0.30) / 0.70 * 0.04
            case .spiralInward:
                let order = Self.spiralOrder[row * 5 + col]
                if reducedMotion { return 0.16 + Double(order) / 24 * 0.78 }
                let delay = Double(order) * 0.04 * 1.5
                guard elapsed >= delay else { return 0.24 }
                let phase = (elapsed - delay).truncatingRemainder(dividingBy: 1.5) / 1.5
                for index in 1..<Self.spiralFrames.count {
                    let end = Self.spiralFrames[index], start = Self.spiralFrames[index - 1]
                    if phase <= end.time {
                        return start.opacity + (end.opacity - start.opacity) * (phase - start.time) / (end.time - start.time)
                    }
                }
                return 0.08
            case .fillAndDrain:
                if reducedMotion { return 0.08 }
                let step = Int(elapsed.truncatingRemainder(dividingBy: 2) / 2 * 24)
                if (10..<14).contains(step) { return Self.blinkOpacities[step - 10] }
                let height = step < 10 ? max(0, min(5, step - col)) : max(0, min(5, 5 - max(0, step - 14 - col)))
                let top = 5 - height
                guard height > 0, row >= top else { return 0.08 }
                return row == top && height < 5 ? 1 : 0.52
            case .equalizer:
                let phase = reducedMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 1.75) / 1.75
                let level = max(1, min(5, Int((1 + (sin(phase * 24 * 0.52 + Double(col) * 1.15) + 1) / 2 * 4).rounded())))
                let top = 5 - level
                return row == top ? 1 : row > top ? 0.94 : 0.08
            case .liquidHex:
                let phase = reducedMotion ? 0.14 : elapsed.truncatingRemainder(dividingBy: 1.85 / 1.55) / (1.85 / 1.55)
                let x = Double(col) - Double(columns(in: row) - 1) / 2
                let y = Double(row - 2) * sqrt(3) / 2
                let radius = hypot(x, y), angle = phase * 2 * Double.pi
                let lens = max(0, 1 - abs(sin(angle) * 1.15 - x * 0.88 - y * 0.16) / 0.78)
                func ripple(_ value: Double, width: Double) -> Double {
                    let wrapped = value - floor(value)
                    return max(0, 1 - min(wrapped, 1 - wrapped) / width)
                }
                let front = ripple(phase + x * 0.12 - y * 0.045 + radius * 0.07, width: 0.16)
                let back = ripple(phase + 0.34 + x * 0.09 + y * 0.035 + radius * 0.05, width: 0.2) * 0.34
                let compression = max(0, 1 - abs(cos(angle) * 1.18 - y * 1.25) / 1.1) * 0.18
                let sheen = (0.5 + 0.5 * sin(angle - radius * 1.9)) * (radius > 1.35 ? 0.16 : 0.06)
                let core = radius < 0.1 ? 0.34 + sin(angle) * 0.1 : 0
                return min(0.98, 0.09 + lens * 0.72 + front * 0.38 + back + compression + sheen + core)
            case .wovenStrands, .narrowHelix:
                let cycle = self == .wovenStrands ? 1.6 : 1.4
                let phase = reducedMotion ? 0 : elapsed.truncatingRemainder(dividingBy: cycle) / cycle
                let rowPhase = phase * (self == .wovenStrands ? 4 : 2) * .pi + Double(row) * 1.24
                let left = Int((self == .wovenStrands ? 1 + sin(rowPhase) : 1.5 + 0.5 * sin(rowPhase)).rounded())
                let right = 4 - left
                if col == left || col == right { return 1 }
                if cos(rowPhase * 2) > 0.82 && col > left && col < right { return 0.58 }
                if abs(col - left) == 1 || abs(col - right) == 1 { return 0.24 }
                return 0.08
            }
        }
    }

    private static let checkPixels: [UInt8] = [0b0000000, 0b0000011, 0b0000110, 0b1001100, 0b1111000, 0b0110000, 0b0000000]
    private static let warningPixels: [UInt8] = [0b0000000, 0b0001100, 0b0001100, 0b0001100, 0b0000000, 0b0001100, 0b0000000]

    let activity: String
    var size: CGFloat = 20
    var status: AgentStatus = .working
    var isVisible = true

    private var statusColor: Color {
        status == .completed ? .green : status == .waitingApproval ? .yellow : .red
    }
    private var accessibilityText: String {
        switch status {
        case .completed: return "Agent completed"
        case .waitingApproval: return "Agent needs approval"
        case .error: return "Agent failed"
        default: return "Agent is active"
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pattern = Pattern.allCases.randomElement() ?? .diagonalSweep
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if reduceMotion || status != .working || !isVisible {
                matrix(elapsed: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    matrix(elapsed: max(0, context.date.timeIntervalSince(startedAt)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onChange(of: [activity, status.rawValue, String(isVisible)]) { _ in
            guard status == .working, isVisible else { return }
            pattern = Pattern.allCases.randomElement() ?? .diagonalSweep
            startedAt = Date()
        }
    }

    private func matrix(elapsed: Double) -> some View {
        Canvas { context, bounds in
            if status != .working {
                let side = min(bounds.width, bounds.height)
                let origin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
                let ring = CGRect(origin: origin, size: CGSize(width: side, height: side)).insetBy(dx: 1, dy: 1)
                context.stroke(Path(ellipseIn: ring), with: .color(statusColor), lineWidth: 1.25)

                // Connected, fine pixels inside a smooth circle; generous inset keeps
                // the symbol separate from the outline at the notch's small size.
                let rows = status == .completed ? Self.checkPixels : Self.warningPixels
                let glyphSize = side * 0.55
                let stride = glyphSize / 7
                let insetX = (bounds.width - glyphSize) / 2
                let insetY = (bounds.height - glyphSize) / 2
                for (row, cells) in rows.enumerated() {
                    for col in 0..<7 where cells & (1 << (6 - col)) != 0 {
                        let rect = CGRect(x: insetX + CGFloat(col) * stride,
                                          y: insetY + CGFloat(row) * stride,
                                          width: stride, height: stride)
                        context.fill(Path(rect), with: .color(statusColor))
                    }
                }
                return
            }
            let diameter = min(bounds.width, bounds.height) / 8
            let stride = (min(bounds.width, bounds.height) - diameter) / 4
            let pitch = pattern == .liquidHex ? sqrt(3.0) / 2 : 1
            let topInset = (bounds.height - (4 * stride * pitch + diameter)) / 2
            for row in 0..<5 {
                let columns = pattern.columns(in: row)
                for col in 0..<columns {
                    let leftInset = (bounds.width - (CGFloat(columns - 1) * stride + diameter)) / 2
                    let rect = CGRect(x: leftInset + CGFloat(col) * stride, y: topInset + CGFloat(row) * stride * pitch,
                                      width: diameter, height: diameter)
                    let opacity = pattern.opacity(row: row, col: col, elapsed: elapsed, reducedMotion: reduceMotion)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                }
            }
        }
    }
}
