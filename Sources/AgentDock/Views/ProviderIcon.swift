import AppKit
import SwiftUI

/// Shared, cached provider PNGs from the app bundle.
@MainActor
enum ProviderIconRegistry {
    private static let rawImages: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for (provider, asset) in [("cursor", "cursor"), ("antigravity", "antigravity"),
                                  ("codex", "codex"), ("claude", "claude"), ("opencode", "opencode")] {
            guard let url = Bundle.main.url(forResource: asset, withExtension: "png", subdirectory: "ProviderIcons"),
                  let image = NSImage(contentsOf: url) else { continue }
            images[provider] = image
        }
        return images
    }()

    private static let menuImages: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for (provider, original) in rawImages {
            guard let copy = original.copy() as? NSImage else { continue }
            let longestSide = max(copy.size.width, copy.size.height)
            if longestSide > 0 {
                copy.size = NSSize(width: copy.size.width * 14 / longestSide,
                                   height: copy.size.height * 14 / longestSide)
            }
            copy.isTemplate = provider == "cursor" || provider == "codex"
            images[provider] = copy
        }
        return images
    }()

    static func image(for provider: String) -> NSImage? { menuImages[provider] }
    static func fullImage(for provider: String) -> NSImage? { rawImages[provider] }
}

/// Every brand uses the same square layout slot, without stretching the original artwork.
struct ProviderIcon: View {
    let provider: String
    var fallbackSymbol = "cpu"
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ProviderIconRegistry.image(for: provider) ?? ProviderIconRegistry.fullImage(for: provider) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Provider icon with connection progress and a configure action on hover.
struct ProviderAppIconTile: View {
    let provider: String
    let name: String
    var isConnecting: Bool = false
    var size: CGFloat = 78
    var isInteractive: Bool = true
    var onConfigure: (() -> Void)? = nil

    @State private var isHovered = false

    var isSettingUp: Bool { isInteractive && isConnecting }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Main Squircle Icon Body
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 32 / 255, green: 34 / 255, blue: 38 / 255),
                                Color(red: 18 / 255, green: 20 / 255, blue: 23 / 255)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Top specular rim lining (Neutral white specular rim)
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.40), location: 0.0),
                                .init(color: Color.white.opacity(0.12), location: 0.25),
                                .init(color: Color.clear, location: 0.60)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.0
                    )

                // Perimeter stroke
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)

                // High-Resolution Provider Logo
                if let nsImage = ProviderIconRegistry.fullImage(for: provider) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.58, height: size * 0.58)
                } else {
                    AppIcon(.processor, size: size * 0.42)
                        .foregroundColor(.white)
                }

                // Progressive black shadow towards bottom on hover to give clear contrast for settings button
                if isInteractive && isHovered {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.clear, location: 0.30),
                                    .init(color: Color.black.opacity(0.40), location: 0.65),
                                    .init(color: Color.black.opacity(0.85), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))

            // On Hover: Secondary Configure Gear Button at bottom-left using CirclePushable3DButton component
            if isInteractive && isHovered && onConfigure != nil {
                let btnSize: CGFloat = max(26, size * 0.25)
                CirclePushable3DButton(
                    size: btnSize,
                    variant: .secondary,
                    cornerRadius: btnSize / 2
                ) {
                    onConfigure?()
                } content: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: btnSize * 0.44, weight: .semibold))
                }
                .padding(size * 0.07)
                .transition(.opacity)
                .help("Configure \(name)")
                .accessibilityLabel("Configure \(name)")
            }
        }
        .frame(width: size, height: size)
        .shadow(
            color: Color.black.opacity(isInteractive && isHovered ? 0.35 : 0.22),
            radius: (isInteractive && isHovered) || isSettingUp ? 12 : 6,
            x: 0,
            y: (isInteractive && isHovered) || isSettingUp ? 6 : 3
        )
        .scaleEffect(isSettingUp ? 1.14 : ((isInteractive && isHovered) ? 1.06 : 1.0))
        .offset(y: (isInteractive && isHovered) ? -6 : (isSettingUp ? -4 : 0))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSettingUp)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { if isInteractive { isHovered = $0 } }
    }
}
