import AppKit
import SwiftUI

/// Layout constants. Sources: TBC farewell CSS + @2x captures (references/design/design-language.md §0).
enum Metrics {
    static let frameInset: CGFloat = 10
    static let cardRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 227
    /// Narrowest sidebar that still fits the toolbar row: 8 + 64 (traffic lights) + 28 (toggle)
    /// + 4 + 3×28 + 2×6 (back/forward/reload) + 8.
    static let sidebarMinWidth: CGFloat = 210
    static let sidebarMaxWidth: CGFloat = 420
    static let sidebarPaddingLeading: CGFloat = 8
    static let sidebarPaddingTrailing: CGFloat = 8
    static let toolbarHeight: CGFloat = 36
    /// Traffic light centres: x 20/40/60 from the window edge, y = frameInset + toolbar/2.
    static let trafficLightFirstCenterX: CGFloat = 20
    static let trafficLightSpacing: CGFloat = 20
    static let urlPillHeight: CGFloat = 35
    static let urlPillRadius: CGFloat = 9
    static let favoriteHeight: CGFloat = 45
    static let favoriteRadius: CGFloat = 10
    static let favoriteGap: CGFloat = 8
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 3
    static let rowRadius: CGFloat = 9
    static let rowIndent: CGFloat = 15
    static let footerHeight: CGFloat = 36
    static let librarySidebarWidth: CGFloat = 400
    /// Floating (hidden-then-revealed) sidebar.
    static let floatingSidebarInset: CGFloat = 6
    static let floatingSidebarRadius: CGFloat = 14
    static let edgeTriggerWidth: CGFloat = 6
    /// The page card's border (Arc draws a slight, visible edge around the page).
    static let cardBorderWidth: CGFloat = 1
}

enum Motion {
    /// Arc's signature expo-out, `cubic-bezier(0.16, 1, 0.3, 1)` (farewell CSS `--ease`).
    static var expoOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }
    static let sidebarToggle: TimeInterval = 0.34
    static let themeCrossfade: TimeInterval = 0.3
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)
}
