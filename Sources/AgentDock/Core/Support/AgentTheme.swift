import AppKit
import SwiftUI

// MARK: - Global Dynamic Theme Tokens (Light & Dark Mode)
/// Single source of truth for semantic colors, mode palettes, surfaces, and geometry tokens.
public enum AgentTheme {
    /// Helper to produce a dynamic `Color` tracking Light vs. Dark appearance via `NSColor`.
    public static func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double),
        alpha: Double = 1.0
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(rgb.0 / 255.0),
                green: CGFloat(rgb.1 / 255.0),
                blue: CGFloat(rgb.2 / 255.0),
                alpha: CGFloat(alpha)
            )
        })
    }

    // MARK: - Canvas & Containers (Surfaces)
    public static let background = dynamic(light: (242, 243, 246), dark: (10, 10, 13))
    public static let foreground = dynamic(light: (18, 20, 24), dark: (255, 255, 255))
    public static let card = dynamic(light: (255, 255, 255), dark: (18, 19, 22))
    public static let cardForeground = dynamic(light: (18, 20, 24), dark: (235, 235, 238))

    // MARK: - Primary & Secondary Brand Tokens (#0b73f9 - Electric Blue)
    // Clean, modern, developer-grade electric blue (#0b73f9)
    public static let primary = dynamic(light: (11, 115, 249), dark: (11, 115, 249))
    public static let primaryForeground = dynamic(light: (255, 255, 255), dark: (255, 255, 255))
    public static let secondary = dynamic(light: (238, 240, 244), dark: (26, 27, 31))

    // MARK: - Muted & Accent
    public static let muted = dynamic(light: (245, 246, 249), dark: (24, 25, 28))
    public static let mutedForeground = dynamic(light: (105, 110, 118), dark: (140, 142, 148))
    public static let accent = dynamic(light: (239, 246, 255), dark: (18, 30, 58))

    // MARK: - Semantic Feedback & System
    public static let destructive = dynamic(light: (235, 68, 62), dark: (245, 75, 75))
    public static let border = dynamic(light: (226, 228, 234), dark: (32, 33, 36))
    public static let input = dynamic(light: (245, 245, 248), dark: (22, 23, 26))
    public static let ring = dynamic(light: (11, 115, 249), dark: (11, 115, 249))

    // Success / Completed: Emerald Green
    public static let success = Color(red: 0.18, green: 0.75, blue: 0.42)

    // Warning / Attention: Golden Amber
    public static let warning = Color(red: 0.98, green: 0.82, blue: 0.20)
    public static let warningGradient = [Color(red: 0.98, green: 0.82, blue: 0.20), Color(red: 0.92, green: 0.65, blue: 0.10)]

    // Tech / Agent Blue (#0b73f9)
    public static let agentBlue = Color(red: 11 / 255.0, green: 115 / 255.0, blue: 249 / 255.0)

    // MARK: - Sidebar & Navigation Chrome
    public static let sidebar = dynamic(light: (255, 255, 255), dark: (16, 17, 20))
    public static let sidebarForeground = dynamic(light: (18, 20, 24), dark: (235, 235, 240))
    public static let sidebarPrimary = dynamic(light: (11, 115, 249), dark: (11, 115, 249))
    public static let sidebarPrimaryForeground = dynamic(light: (255, 255, 255), dark: (255, 255, 255))
    public static let sidebarAccent = dynamic(light: (239, 246, 255), dark: (18, 30, 58))
    public static let sidebarBorder = dynamic(light: (226, 228, 234), dark: (32, 33, 36))

    // MARK: - Corner Radius Tokens (base 1.3rem = 20.8pt)
    public static let radius: CGFloat = 20.8
    public static var radiusXs: CGFloat { max(4.0, radius - 6.0) }  // 14.8 pt
    public static var radiusSm: CGFloat { max(6.0, radius - 4.0) }  // 16.8 pt
    public static var radiusMd: CGFloat { max(8.0, radius - 2.0) }  // 18.8 pt
    public static var radiusXl: CGFloat { radius + 4.0 }           // 24.8 pt

    // Semantic Element Roundness Variables

    /// Dynamic button corner roundness based on size and global radius token
    public static func radiusForButton(size: CGFloat? = nil, isSmall: Bool = false) -> CGFloat {
        let target = isSmall ? radiusSm : radius
        if let size = size {
            return min(size / 2.0, target)
        }
        return target
    }
}
