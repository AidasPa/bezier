import AppKit
import BezierCore
import SwiftUI

/// One Space's part of the sidebar: header, pinned tree, divider, New Tab, Today.
/// This is the part that slides when switching Spaces.
struct SpaceSection: View {
    let controller: BrowserWindowController
    let model: BrowserModel
    let space: Space
    let state: WindowState
    let palette: ThemePalette

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                SpaceHeader(controller: controller, space: space, state: state, palette: palette)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(space.pinned) { node in
                    NodeRows(controller: controller, node: node, depth: 0, location: .pinned(spaceID: space.id),
                             state: state, palette: palette)
                }
                TodayDivider(space: space, controller: controller, palette: palette)
                NewTabRow(palette: palette) { controller.newTab(nil) }
                    .sidebarDraggable(id: space.id, drag: state.drag, dropTarget: (space.id, space.id), dropKind: .todayTop,
                                      palette: palette, canDrag: false, onClick: { _ in controller.newTab(nil) }) { controller.handleSidebarDrop($0, $1) }
                ForEach(TodayItem.items(for: space)) { item in
                    TodayItemView(controller: controller, space: space, item: item, state: state, palette: palette)
                }
            }
            .padding(.bottom, 12)
            .coordinateSpace(name: SidebarDragState.space)
        }
        .scrollIndicators(.never)
    }
}

/// Icon + name; hover shows the theme brush and a "…" menu. Clicking the icon changes it,
/// double-clicking the name renames the Space.
private struct SpaceHeader: View {
    let controller: BrowserWindowController
    let space: Space
    let state: WindowState
    let palette: ThemePalette

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private func panelBinding(_ panel: SpaceEditorPanel) -> Binding<Bool> {
        Binding(
            get: { state.spaceEditor == SpaceEditor(spaceID: space.id, panel: panel) },
            set: { if !$0, state.spaceEditor?.panel == panel { state.spaceEditor = nil } }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.editSpace(space, panel: .icon) } label: {
                Group {
                    if let icon = space.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 11.5))
                    } else if hovering {
                        Image(systemName: "face.smiling").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
                    }
                }
                .frame(minWidth: hovering || space.icon != nil ? 16 : 0, minHeight: 16)
            }
            .buttonStyle(PressableStyle(scale: 0.8))
            .help("Change Icon")
            .popover(isPresented: panelBinding(.icon), arrowEdge: .bottom) {
                IconPicker(current: space.icon) { icon in
                    controller.model.setIcon(icon, for: space)
                    state.spaceEditor = nil
                }
            }

            if state.renamingSpaceID == space.id {
                TextField("Space name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .focused($renameFocused)
                    .onAppear { draft = space.title; renameFocused = true }
                    .onSubmit { controller.finishRenameSpace(space, title: draft) }
                    .onExitCommand { controller.finishRenameSpace(space, title: nil) }
            } else {
                Text(space.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.12)
                    .foregroundStyle(palette.muted)
                    .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { controller.beginRenameSpace(space) } }
                if space.profile != "default" {
                    HStack(spacing: 3) {
                        Image(systemName: "person.crop.circle").font(.system(size: 10, weight: .semibold))
                        Text(space.profile).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(palette.muted.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(palette.rowHover))
                    .help("Profile: \(space.profile)")
                }
            }
            Spacer(minLength: 0)
            Group {
                Button { controller.editSpace(space, panel: .theme) } label: {
                    Image(systemName: "paintbrush").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.icon)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.8))
                .help("Edit Theme")
                .popover(isPresented: panelBinding(.theme), arrowEdge: .trailing) {
                    ThemeEditor(controller: controller, space: space)
                }
                Menu { SpaceMenu(controller: controller, space: space) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.icon)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .opacity(hovering || state.spaceEditor?.spaceID == space.id ? 1 : 0)
        }
        .padding(.leading, 11.5)
        .padding(.trailing, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { SpaceMenu(controller: controller, space: space) }
    }
}

private struct NodeRows: View {
    let controller: BrowserWindowController
    let node: SidebarNode
    let depth: Int
    let location: TabLocation
    let state: WindowState
    let palette: ThemePalette

    var body: some View {
        switch node {
        case .tab(let tab):
            TabRow(controller: controller, tab: tab, depth: depth, location: location, state: state, palette: palette)
        case .folder(let folder):
            FolderRow(controller: controller, folder: folder, depth: depth, palette: palette)
            if folder.isExpanded {
                ForEach(folder.children) { child in
                    NodeRows(controller: controller, node: child, depth: depth + 1, location: location,
                             state: state, palette: palette)
                }
            }
        }
    }
}

private struct FolderRow: View {
    let controller: BrowserWindowController
    let folder: Folder
    let depth: Int
    let palette: ThemePalette

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11.5) {
            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.accent)
                .frame(width: 18, height: 18)
            Text(folder.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 9.5 + CGFloat(depth) * Metrics.rowIndent)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
            .fill(hovering ? palette.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sidebarDraggable(id: folder.id, drag: controller.state.drag, dropTarget: (folder.id, folder.id), dropKind: .folder,
                          palette: palette, canDrag: false,
                          onClick: { _ in withAnimation(Motion.snappy) { controller.toggle(folder) } }) { controller.handleSidebarDrop($0, $1) }
    }
}

struct TabRow: View {
    let controller: BrowserWindowController
    let tab: BrowserTab
    let depth: Int
    let location: TabLocation
    let state: WindowState
    let palette: ThemePalette

    @State private var hovering = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var selected: Bool { state.selectedTabID == tab.id }
    private var isPinned: Bool { if case .pinned = location { true } else { false } }
    private var isToday: Bool { if case .today = location { true } else { false } }
    private var isDev: Bool { controller.isDeveloperMode(tab) }

    var body: some View {
        HStack(spacing: 11.5) {
            FaviconView(url: tab.faviconURL, pageURL: tab.url ?? tab.pinnedURL, title: tab.displayTitle)
                .frame(width: 18, height: 18)
            if state.renamingTabID == tab.id {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .focused($renameFocused)
                    .onAppear { draftTitle = tab.displayTitle; renameFocused = true }
                    .onSubmit { controller.finishRename(tab, title: draftTitle) }
                    .onExitCommand { controller.finishRename(tab, title: nil) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        if isPinned && tab.hasDriftedFromPinnedURL {
                            Text("/").foregroundStyle(palette.inkSecondary)
                        }
                        Text(tab.displayTitle).foregroundStyle(palette.ink)
                    }
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    if isDev, let site = DeveloperMode.siteKey(tab.url) {
                        Text(site).font(.system(size: 11)).foregroundStyle(palette.inkSecondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let media = controller.app.media.states[tab.id], media.isPlaying || media.isMuted {
                Button { controller.app.contents.existingContent(for: tab)?.perform(.setMuted(!media.isMuted)) } label: {
                    Image(systemName: media.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.icon)
                        .symbolEffect(.variableColor.iterative, isActive: media.isPlaying && !media.isMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.8))
                .help(media.isMuted ? "Unmute Tab" : "Mute Tab")
                .transition(.scale.combined(with: .opacity))
            }
            if hovering && state.renamingTabID != tab.id {
                Button { controller.closeTab(tab) } label: {
                    Image(systemName: isPinned ? "minus" : "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(palette.icon)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.rowHover))
                }
                .buttonStyle(PressableStyle(scale: 0.8))
                .help(isPinned ? "Unload Tab" : "Archive Tab (⌘W)")
            }
        }
        .padding(.leading, 9.5 + CGFloat(depth) * Metrics.rowIndent)
        .padding(.trailing, 7)
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(selected ? palette.activeTab : (hovering ? palette.rowHover : .clear))
                .animation(Motion.snappy, value: selected)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // First click selects; a double-click on an already selected tab renames.
        .sidebarDraggable(id: tab.id, drag: state.drag, dropTarget: (tab.id, tab.id), dropKind: isToday ? .today : .pinned,
                          palette: palette, onClick: { clicks in
                              if clicks == 2 && selected { controller.beginRename(tab) } else { controller.select(tab) }
                          }) { controller.handleSidebarDrop($0, $1) }
        .contextMenu { TabContextMenu(controller: controller, tab: tab, isPinned: isPinned) }
    }
}

private struct TabContextMenu: View {
    let controller: BrowserWindowController
    let tab: BrowserTab
    let isPinned: Bool

    var body: some View {
        Button("Copy Link") { controller.copy(tab.url) }
        Button("Rename…") { controller.beginRename(tab) }
        Button("Duplicate") { controller.duplicate(tab) }
        Divider()
        Button(isPinned ? "Unpin Tab" : "Pin Tab") { controller.togglePin(tab) }
        Button("Add to Favorites") { controller.addToFavorites(tab) }
        Menu("Move to Space") {
            ForEach(controller.model.spaces.filter { $0.id != controller.state.spaceID }) { space in
                Button("\(space.icon ?? "") \(space.title)") { controller.move(tab, to: space) }
            }
        }
        if isPinned {
            Button("Reset to Original URL") { controller.resetToPinnedURL(tab) }
        }
        Divider()
        Button(isPinned ? "Unload Tab" : "Archive Tab") { controller.closeTab(tab) }
    }
}

private struct TodayDivider: View {
    let space: Space
    let controller: BrowserWindowController
    let palette: ThemePalette

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                if !space.today.isEmpty {
                    Button { withAnimation(Motion.spring) { controller.clearToday(nil) } } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down").font(.system(size: 9.5, weight: .semibold))
                            Text("Clear").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(palette.muted.opacity(hovering ? 1 : 0.8))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .help("Clear Unpinned Tabs (⇧⌘K)")
                }
            }
            .frame(height: 14)
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.75)
                .padding(.horizontal, 2)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onHover { hovering = $0 }
    }
}

private struct NewTabRow: View {
    let palette: ThemePalette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11.5) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
            Text("New Tab").font(.system(size: 13.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.newTab)
        .padding(.leading, 9.5)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
            .fill(hovering ? palette.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Today, with grouped tabs folded into one item and Split Views folded into one row.
@MainActor
enum TodayItem: @MainActor Identifiable {
    case tab(BrowserTab)
    case split(UUID, [BrowserTab])
    case group(TabGroup, [BrowserTab])

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .split(let id, _): id
        case .group(let group, _): group.id
        }
    }

    static func items(for space: Space) -> [TodayItem] {
        var items: [TodayItem] = []
        var seenGroups = Set<UUID>()
        var loose: [BrowserTab] = []
        func flush() { items += rows(loose, in: space); loose.removeAll() }
        for tab in space.today {
            if let id = tab.groupID, let group = space.group(id) {
                flush()
                if seenGroups.insert(id).inserted { items.append(.group(group, space.members(of: id))) }
            } else {
                loose.append(tab)
            }
        }
        flush()
        return items
    }

    /// Folds Split View panes in `tabs` into one row each.
    static func rows(_ tabs: [BrowserTab], in space: Space) -> [TodayItem] {
        var items: [TodayItem] = []
        var seenSplits = Set<UUID>()
        for tab in tabs {
            if let id = tab.splitID {
                if seenSplits.insert(id).inserted { items.append(.split(id, space.panes(of: id))) }
            } else {
                items.append(.tab(tab))
            }
        }
        return items
    }
}

private struct TodayItemView: View {
    let controller: BrowserWindowController
    let space: Space
    let item: TodayItem
    let state: WindowState
    let palette: ThemePalette

    var body: some View {
        switch item {
        case .tab(let tab):
            TabRow(controller: controller, tab: tab, depth: 0, location: .today(spaceID: space.id), state: state, palette: palette)
        case .split(let id, let tabs):
            SplitRow(controller: controller, space: space, splitID: id, tabs: tabs, state: state, palette: palette)
        case .group(let group, let tabs):
            TabGroupView(controller: controller, space: space, group: group, tabs: tabs, state: state, palette: palette)
        }
    }
}

/// A Split View in the sidebar: one pill holding each pane's favicon and title, split by
/// hairlines (Arc's layout). The focused pane reads strongest.
private struct SplitRow: View {
    let controller: BrowserWindowController
    let space: Space
    let splitID: UUID
    let tabs: [BrowserTab]
    let state: WindowState
    let palette: ThemePalette

    @State private var hovering = false

    private var selected: Bool { tabs.contains { $0.id == state.selectedTabID } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle().fill(palette.hairline).frame(width: 1, height: 18)
                }
                let focused = tab.id == state.selectedTabID
                HStack(spacing: 7) {
                    FaviconView(url: tab.faviconURL, pageURL: tab.url ?? tab.pinnedURL, title: tab.displayTitle)
                    Text(tab.displayTitle)
                        .font(.system(size: 13, weight: focused ? .semibold : .medium))
                        .foregroundStyle(palette.ink.opacity(selected && !focused ? 0.62 : 1))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .sidebarDraggable(id: tab.id, drag: state.drag, dropTarget: nil, palette: palette,
                                  onClick: { _ in controller.select(tab) }) { controller.handleSidebarDrop($0, $1) }
                .contextMenu {
                    Button(tab.splitStacked ? "Arrange Side by Side" : "Arrange Top to Bottom") { controller.toggleSplitArrangement(splitID) }
                    Button("Separate Split View") { controller.separateSplit(splitID) }
                    Button("Close This Pane") { controller.closeTab(tab) }
                }
            }
        }
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(selected ? palette.activeTab : (hovering ? palette.rowHover : .clear))
                .animation(Motion.snappy, value: selected)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sidebarDraggable(id: splitID, drag: state.drag, dropTarget: (tabs.first!.id, tabs.last!.id), palette: palette,
                          canDrag: false) { controller.handleSidebarDrop($0, $1) }
        .zIndex(tabs.contains { $0.id == state.drag.draggingID } ? 10 : 0)    // a dragged pane draws over later rows
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

/// Tabs a page opened, shown together under a collapsible header (double-click to rename).
private struct TabGroupView: View {
    let controller: BrowserWindowController
    let space: Space
    let group: TabGroup
    let tabs: [BrowserTab]
    let state: WindowState
    let palette: ThemePalette

    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                    .foregroundStyle(palette.muted)
                    .frame(width: 12)
                if renaming {
                    TextField("Group name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .focused($focused)
                        .onAppear { draft = group.title; focused = true }
                        .onSubmit { controller.model.renameGroup(group.id, to: draft, in: space); renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    Text(group.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(tabs.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted.opacity(0.9))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(palette.rowHover))
                if hovering {
                    Button { withAnimation(Motion.spring) { controller.closeGroup(group.id, in: space) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(palette.icon)
                    }
                    .buttonStyle(PressableStyle(scale: 0.8))
                    .help("Close Group")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 {
                    renaming = true
                } else {
                    withAnimation(Motion.snappy) { controller.model.toggleGroupCollapsed(group.id, in: space) }
                }
            }
            .contextMenu {
                Button("Rename Group") { renaming = true }
                Button("Ungroup Tabs") { withAnimation(Motion.spring) { controller.model.ungroup(group.id, in: space) } }
                Divider()
                Button("Close Group") { withAnimation(Motion.spring) { controller.closeGroup(group.id, in: space) } }
            }

            ForEach(TodayItem.rows(tabs.filter { !group.isCollapsed || $0.id == state.selectedTabID }, in: space)) { item in
                TodayItemView(controller: controller, space: space, item: item, state: state, palette: palette)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius + 3, style: .continuous).fill(palette.rowHover))
        .overlay(alignment: exit?.below == true ? .bottom : .top) { exitHint }
        .sidebarGroupFrame(id: group.id, members: tabs.map(\.id), drag: state.drag)
        .padding(.vertical, 2)
        .zIndex(tabs.contains { $0.id == state.drag.draggingID } ? 10 : 0)    // a dragged member draws over later rows
    }

    private var exit: GroupExit? { state.drag.groupExit?.groupID == group.id ? state.drag.groupExit : nil }

    /// Where a tab pulled out of the group will land: a line just above or below it.
    @ViewBuilder private var exitHint: some View {
        if let exit {
            Capsule()
                .fill(palette.accent)
                .frame(height: 3)
                .shadow(color: palette.accent.opacity(0.6), radius: 4)
                .padding(.horizontal, 6)
                .offset(y: (exit.below ? 1 : -1) * (2 + Metrics.rowSpacing / 2 + 1.5))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }
}
