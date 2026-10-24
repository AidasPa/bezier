import AppKit
import BezierCore
import Observation

/// Per-window UI state. The sidebar data is shared (BrowserModel); which Space is showing,
/// which tab is selected and how the sidebar is presented are per window.
@MainActor
@Observable
final class WindowState {
    var spaceID: UUID
    /// Last selected tab per space, so switching spaces restores context (Arc v1.3).
    var selectedTabBySpace: [UUID: UUID] = [:]
    /// Docked in the window frame. When false the sidebar is hidden (⌘S) and can float out.
    var sidebarVisible = true
    /// Hidden sidebar currently slid out as a floating panel (pointer at the left edge).
    var sidebarRevealed = false
    var sidebarWidth: CGFloat
    var palette: ThemePalette
    /// +1 when moving to a later space, -1 to an earlier one; drives the sidebar slide.
    var spaceTransitionDirection: CGFloat = 1
    /// How far a two-finger swipe over the sidebar has dragged the current Space.
    var spaceSwipeOffset: CGFloat = 0
    var renamingTabID: UUID?
    var renamingSpaceID: UUID?
    /// Theme or icon popover open for a Space.
    var spaceEditor: SpaceEditor?
    /// Sidebar shows the Library instead of tabs (Arc: bottom-left box icon, ⇧⌘L).
    var isLibraryOpen = false
    /// Library reopens on the last section used (Arc v1.19.1).
    var librarySection: LibrarySection = .archive
    /// Portrait Mode popover (dev toolbar button or Command Bar).
    var portraitCaptureOpen = false
    let toasts = ToastCenter()
    /// Live tab drag in the sidebar (drop on an edge to split, on the middle to group).
    let drag = SidebarDragState()
    /// ⌘F find bar.
    let find = FindModel()
    /// ⌃Tab recent-tabs switcher.
    let switcher = TabSwitcherModel()

    /// Library mode widens the sidebar to fit the section rail.
    var effectiveSidebarWidth: CGFloat { isLibraryOpen ? max(sidebarWidth, Metrics.librarySidebarWidth) : sidebarWidth }

    private static let widthKey = "SidebarWidth"

    init(space: Space, systemIsDark: Bool) {
        spaceID = space.id
        palette = ThemePalette(theme: space.theme, systemIsDark: systemIsDark)
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        sidebarWidth = saved > 0 ? min(Metrics.sidebarMaxWidth, max(Metrics.sidebarMinWidth, saved)) : Metrics.sidebarWidth
    }

    var selectedTabID: UUID? {
        get { selectedTabBySpace[spaceID] }
        set { selectedTabBySpace[spaceID] = newValue }
    }

    /// Floating panels sit `floatingSidebarInset` from the window edge; the sidebar content
    /// shifts by that much so the traffic lights stay put.
    var sidebarOriginX: CGFloat { sidebarVisible ? 0 : Metrics.floatingSidebarInset }

    func persistSidebarWidth() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey)
    }
}

enum SpaceEditorPanel { case theme, icon }

struct SpaceEditor: Equatable {
    let spaceID: UUID
    let panel: SpaceEditorPanel
}
