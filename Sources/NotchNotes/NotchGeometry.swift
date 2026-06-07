import AppKit
import CoreGraphics
import SwiftUI

struct NotchLayout: Equatable {
    let notchSize: NSSize
    let compactSize: NSSize
    let expandedSize: NSSize
    let compactTopOffset: CGFloat
    let expandedTopOffset: CGFloat
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    var isBuiltInDisplay: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    var measuredNotchSize: NSSize {
        guard #available(macOS 12.0, *), safeAreaInsets.top > 0 else {
            return .zero
        }

        guard let leftArea = auxiliaryTopLeftArea, let rightArea = auxiliaryTopRightArea else {
            return .zero
        }

        let notchWidth = frame.width - leftArea.width - rightArea.width
        guard notchWidth > 0, notchWidth < frame.width else {
            return .zero
        }

        return NSSize(width: notchWidth, height: safeAreaInsets.top)
    }
}

@MainActor
enum NotchGeometry {
    /// Fallback screen dimensions when the actual screen cannot be determined.
    static let fallbackScreenSize = NSSize(width: 1440, height: 900)
    static var fallbackScreenFrame: NSRect {
        NSRect(origin: .zero, size: fallbackScreenSize)
    }

    // MARK: - Compact panel layout constraints
    private static let fallbackNotchSize = NSSize(width: 210, height: 32)
    private static let compactWidthRange: ClosedRange<CGFloat> = 182...238
    private static let compactWidthInset: CGFloat = 6
    private static let compactHeightRange: ClosedRange<CGFloat> = 32...38
    private static let compactHeightPad: CGFloat = 2

    // MARK: - Expanded panel layout constraints
    private static let expandedWidthExtra: CGFloat = 220
    private static let expandedWidthRange: ClosedRange<CGFloat> = 480...540
    private static let expandedHorizontalMargin: CGFloat = 36
    private static let expandedHeightExtra: CGFloat = 374
    private static let expandedMinHeight: CGFloat = 408
    private static let expandedVerticalMargin: CGFloat = 84

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: \.isBuiltInDisplay)
            ?? NSScreen.screens.first { $0.measuredNotchSize != .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen?) -> NotchLayout {
        let screenFrame = screen?.frame ?? fallbackScreenFrame
        let measured = screen?.measuredNotchSize ?? .zero
        let notch = measured == .zero ? fallbackNotchSize : measured

        let compactWidth = min(max(notch.width - compactWidthInset, compactWidthRange.lowerBound), compactWidthRange.upperBound)
        let compactHeight = min(max(notch.height + compactHeightPad, compactHeightRange.lowerBound), compactHeightRange.upperBound)
        let expandedWidth = min(max(notch.width + expandedWidthExtra, expandedWidthRange.lowerBound), expandedWidthRange.upperBound, screenFrame.width - expandedHorizontalMargin)
        let expandedHeight = min(max(notch.height + expandedHeightExtra, expandedMinHeight), screenFrame.height - expandedVerticalMargin)

        return NotchLayout(
            notchSize: notch,
            compactSize: NSSize(width: compactWidth, height: compactHeight),
            expandedSize: NSSize(width: expandedWidth, height: expandedHeight),
            compactTopOffset: 0,
            expandedTopOffset: 0
        )
    }
}

// MARK: - Shared Theme Colors

extension Color {
    static let notchBackground = Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98)
    static let editorBackground = Color(red: 0.06, green: 0.06, blue: 0.07)
}
