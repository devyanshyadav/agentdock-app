import AppKit

public enum NotchStyle: String, CaseIterable, Identifiable, Sendable {
    case stepped, rounded
    public var id: String { rawValue }
    public var title: String { self == .stepped ? "Stepped" : "Rounded" }
}

public struct NotchGeometry: Equatable {
    public let hasPhysicalNotch: Bool
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let showsBottomText: Bool
    public let style: NotchStyle

    public let earWidth: CGFloat
    public let providerIconSize: CGFloat
    public let topFilletRadius: CGFloat
    public let bottomCornerRadius: CGFloat
    public let chinHeight: CGFloat
    public let bottomPadding: CGFloat
    private let compactness: CGFloat

    public var wingHeight: CGFloat { max(notchHeight + 4 - 2 * compactness, providerIconSize + 12 - 4 * compactness) }

    public var totalWidth: CGFloat {
        notchWidth + (earWidth * 2) + (topFilletRadius * 2)
    }

    public var textAreaWidth: CGFloat {
        style == .rounded ? notchWidth + 2 * earWidth : notchWidth
    }

    public var totalHeight: CGFloat {
        showsBottomText ? max(wingHeight, textTopInset + chinHeight + bottomPadding) : wingHeight
    }

    public init(screenFrame: CGRect, visibleFrame: CGRect? = nil,
                topLeftArea: CGRect? = nil, topRightArea: CGRect? = nil, safeAreaTop: CGFloat = 0,
                showsBottomText: Bool = true, compactness: Double = 0, style: NotchStyle = .stepped) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame ?? screenFrame
        self.showsBottomText = showsBottomText
        self.style = style
        let amount = CGFloat(compactness.isFinite ? min(1, max(0, compactness)) : 0)
        self.compactness = amount
        earWidth = 30 - 6 * amount
        providerIconSize = 20 - 4 * amount
        topFilletRadius = 12 - 2 * amount
        bottomCornerRadius = 14 - 3 * amount
        chinHeight = 18 - 2 * amount
        bottomPadding = 3 - 2 * amount
        let gap = topLeftArea.flatMap { left in topRightArea.map { $0.minX - left.maxX } } ?? 0
        hasPhysicalNotch = gap > 0 && (safeAreaTop > 0 || (topLeftArea?.height ?? 0) > 0)
        if hasPhysicalNotch {
            // Preserve the actual camera housing; never substitute a model-specific size.
            notchWidth = gap
            notchHeight = max(safeAreaTop, topLeftArea?.height ?? 0)
        } else {
            notchWidth = showsBottomText ? min(240 - 40 * amount, max(140, self.visibleFrame.width - 2 * (earWidth + topFilletRadius) - 24)) : 12
            notchHeight = 0
        }
    }

    public var textTopInset: CGFloat {
        hasPhysicalNotch ? notchHeight : wingHeight
    }

    public static func current() -> NotchGeometry {
        // Select the display where the user is interacting, not always the laptop panel.
        let preferredID = UserDefaults.standard.string(forKey: AppPreferences.displayKey) ?? ""
        let showsBottomText = UserDefaults.standard.object(forKey: AppPreferences.bottomTextKey) as? Bool ?? true
        let compactness = UserDefaults.standard.double(forKey: AppPreferences.compactnessKey)
        let style = NotchStyle(rawValue: UserDefaults.standard.string(forKey: AppPreferences.notchStyleKey) ?? "") ?? .stepped
        return current(displayID: preferredID, showsBottomText: showsBottomText, compactness: compactness, style: style)
    }

    public static func current(displayID: String, showsBottomText: Bool, compactness: Double, style: NotchStyle) -> NotchGeometry {
        let pinned = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == displayID
        }
        let screen = pinned ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 showsBottomText: showsBottomText, compactness: compactness, style: style)
        }
        return NotchGeometry(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                             topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea,
                             safeAreaTop: screen.safeAreaInsets.top,
                             showsBottomText: showsBottomText, compactness: compactness, style: style)
    }

    public func notchWindowFrame() -> CGRect {
        let w = totalWidth
        let h = totalHeight

        let center = screenFrame.midX
        let x = center - (w / 2)
        // The notch always sticks flush to the top edge of the screen.
        let top = screenFrame.maxY
        let y = top - h

        return CGRect(x: x, y: y, width: w, height: h)
    }
}
