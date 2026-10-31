import SwiftUI
import AppKit

public struct AppLogoView: View {
    public var size: CGFloat
    public var cornerRadius: CGFloat

    public init(size: CGFloat = 36, cornerRadius: CGFloat = 10) {
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        if let image = loadLogoImage() {
            Image(nsImage: image)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: Color.black.opacity(0.20), radius: 3, x: 0, y: 1.5)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AgentTheme.primary, AgentTheme.primary.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                AppIcon(.activity, size: size * 0.45)
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private func loadLogoImage() -> NSImage? {
        // AppKit caches named bundle images; view updates do not reopen PNG files.
        let name = size <= 40 ? "AppLogo@2x" : size <= 80 ? "AppLogo@3x" : "AppLogo512"
        return NSImage(named: NSImage.Name(name)) ?? NSImage(named: NSImage.Name("AppLogo"))
    }
}
