import AppKit
import SwiftUI

/// Native vector icons, tinted by the surrounding view's foreground style.
@MainActor
public struct AppIcon: View {
    public enum Name: String, CaseIterable {
        case preview, activity, shieldCheck, processor, openSource, github, connect, home, productiveApps
    }

    public enum Source {
        case system(String)
        case custom(Name)
    }

    let source: Source
    let size: CGFloat

    public init(_ name: Name, size: CGFloat = 20) {
        self.init(.custom(name), size: size)
    }

    public init(_ source: Source, size: CGFloat = 20) {
        self.source = source
        self.size = size
    }

    private static let images: [Name: NSImage] = {
        var images: [Name: NSImage] = [:]
        for name in Name.allCases {
            guard let image = loadIcon(for: name) else {
                assertionFailure("Missing icon: \(name.rawValue)")
                continue
            }
            images[name] = image
        }
        return images
    }()

    private static func loadIcon(for name: Name) -> NSImage? {
        let ext = name == .productiveApps ? "svg" : "pdf"
        guard let url = Bundle.main.url(forResource: name.rawValue, withExtension: ext, subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    public var body: some View {
        Group {
            switch source {
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
            case .custom(let name):
                if let image = Self.images[name] {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
