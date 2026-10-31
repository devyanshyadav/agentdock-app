import AppKit
import CoreText
import SwiftUI

// MARK: - Bundled font registration
public enum AgentFonts {
    private static var isRegistered: Bool = false

    /// Registers the bundled Google / Vercel Fonts (Geist, Plus Jakarta Sans & Instrument Serif) into the running process.
    public static func registerFonts() {
        guard !isRegistered else { return }
        isRegistered = true

        let fontNames = ["InstrumentSerif-Regular.ttf", "PlusJakartaSans-Variable.ttf", "Geist-Variable.ttf"]

        // Check bundle resources first
        if let resourceURL = Bundle.main.resourceURL {
            let fontsURL = resourceURL.appendingPathComponent("Fonts")
            registerFromDirectory(fontsURL, names: fontNames)
        }
    }

    private static func registerFromDirectory(_ dir: URL, names: [String]) {
        for name in names {
            let fontURL = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fontURL.path) {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            }
        }
    }

    // Font Family Names
    public static let sansFamily = "Plus Jakarta Sans"
    public static let headingFamily = "Geist"
    public static let serifFamily = "Instrument Serif"
}

// MARK: - Semantic SwiftUI Font Extensions
extension Font {
    /// Instrument Serif font for elegant editorial titles, labels and buttons
    public static func instrumentSerif(size: CGFloat) -> Font {
        AgentFonts.registerFonts()
        return Font.custom(AgentFonts.serifFamily, size: size)
    }

    /// Clean body & UI font (Plus Jakarta Sans) with graceful fallback
    public static func agentSans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AgentFonts.registerFonts()
        return Font.custom(AgentFonts.sansFamily, size: size).weight(weight)
    }

    /// Modern, clean & professional heading/display font (Geist) for titles, tabs, card labels
    public static func agentHeading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        AgentFonts.registerFonts()
        return Font.custom(AgentFonts.headingFamily, size: size).weight(weight)
    }
}
