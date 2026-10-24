import BezierCore
import BezierEngine
import SwiftUI

/// Arc's sidebar, top to bottom: toolbar row (traffic lights live here), URL pill, Favorites,
/// the Space's pinned section, divider + "Clear", "+ New Tab", Today tabs, footer.
/// In Library mode the same column widens into the Library.
/// Spec: references/design/design-language.md §2.
struct SidebarView: View {
    let controller: BrowserWindowController
    let model: BrowserModel
    let state: WindowState

    var body: some View {
        let palette = state.palette
        Group {
            if state.isLibraryOpen {
                LibraryView(controller: controller, state: state, palette: palette)
                    .transition(.opacity.combined(with: .offset(x: -12)))
            } else {
                tabs(palette: palette)
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
        }
        .padding(.leading, Metrics.sidebarPaddingLeading)
        .padding(.trailing, Metrics.sidebarPaddingTrailing)
        .padding(.top, Metrics.frameInset - state.sidebarOriginX)
        .padding(.bottom, Metrics.frameInset - state.sidebarOriginX)
        .background(WindowDragArea())
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .animation(.easeInOut(duration: Motion.themeCrossfade), value: palette)
    }

    private func tabs(palette: ThemePalette) -> some View {
        VStack(spacing: 0) {
            SidebarToolbar(controller: controller, content: controller.selectedContent, palette: palette,
                           originX: state.sidebarOriginX)
            URLPill(controller: controller, tab: controller.selectedTab, content: controller.selectedContent,
                    showFullURL: controller.app.settings.showFullURL, palette: palette)
                .padding(.top, 4.5)
            if !model.favorites.isEmpty {
                FavoritesGrid(controller: controller, favorites: model.favorites, selectedID: state.selectedTabID, palette: palette)
                    .padding(.top, 18)
            }
            ZStack {
                if let space = model.space(state.spaceID) {
                    SpaceSection(controller: controller, model: model, space: space, state: state, palette: palette)
                        .offset(x: state.spaceSwipeOffset)
                        .opacity(1 - min(0.5, abs(state.spaceSwipeOffset) / 240))
                        .id(space.id)
                        .transition(.asymmetric(
                            insertion: .offset(x: 40 * state.spaceTransitionDirection).combined(with: .opacity),
                            removal: .offset(x: -40 * state.spaceTransitionDirection).combined(with: .opacity)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            if let id = controller.app.media.miniPlayerTab(excluding: state.selectedTabID), let tab = model.tab(id: id),
               let media = controller.app.media.states[id] {
                MiniPlayer(controller: controller, tab: tab, media: media, palette: palette)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            SidebarFooter(controller: controller, model: model, state: state, palette: palette)
        }
    }
}

// MARK: - Toolbar row

private struct SidebarToolbar: View {
    let controller: BrowserWindowController
    let content: (any WebContent)?
    let palette: ThemePalette
    /// Distance from the window's left edge to the sidebar (non-zero when floating).
    let originX: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Room for the traffic lights (centres at 20/40/60pt from the window edge).
            Color.clear.frame(width: 64 - originX)
            IconButton(symbol: "sidebar.left", palette: palette, help: "Toggle Sidebar (⌘S)") { controller.toggleSidebar(nil) }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                IconButton(symbol: "arrow.left", palette: palette, enabled: content?.state.canGoBack ?? false, help: "Back") {
                    controller.goBack(nil)
                }
                IconButton(symbol: "arrow.right", palette: palette, enabled: content?.state.canGoForward ?? false, help: "Forward") {
                    controller.goForward(nil)
                }
                if content?.state.isLoading == true {
                    IconButton(symbol: "xmark", palette: palette, help: "Stop") { controller.stopLoading(nil) }
                } else {
                    IconButton(symbol: "arrow.clockwise", palette: palette, enabled: content != nil, help: "Reload") {
                        controller.reloadPage(nil)
                    }
                }
            }
            .fixedSize()
        }
        .frame(height: Metrics.toolbarHeight)
    }
}

struct IconButton: View {
    let symbol: String
    let palette: ThemePalette
    var enabled = true
    var size: CGFloat = 14
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(enabled ? palette.icon : palette.iconDisabled)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && enabled ? palette.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.86))
        .fixedSize()
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - URL pill

private struct URLPill: View {
    let controller: BrowserWindowController
    let tab: BrowserTab?
    let content: (any WebContent)?
    let showFullURL: Bool
    let palette: ThemePalette

    @State private var hovering = false

    private var text: String {
        guard let url = tab?.url ?? tab?.pinnedURL else { return "" }
        guard showFullURL else { return URLInput.displayHost(url) }
        return url.absoluteString.replacing(#/^https?://(www\.)?/#, with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            if tab != nil {
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.ink.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hovering {
                    Button { controller.copyURL(nil) } label: {
                        Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.icon)
                    }
                    .buttonStyle(PressableStyle(scale: 0.8))
                    .help("Copy URL (⇧⌘C)")
                }
            } else {
                Text("Search or Enter URL…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.inkSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.urlPillHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.urlPillRadius, style: .continuous)
            .fill(hovering ? palette.wellHover : palette.well))
        .overlay(alignment: .bottom) { LoadingBar(content: content, palette: palette) }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.urlPillRadius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.openLocation(nil) }
        .pressScale(0.985)
    }
}

/// Thin progress sweep along the bottom of the URL pill while a page loads.
private struct LoadingBar: View {
    let content: (any WebContent)?
    let palette: ThemePalette

    var body: some View {
        let loading = content?.state.isLoading ?? false
        let progress = content?.state.progress ?? 0
        GeometryReader { geo in
            Capsule()
                .fill(palette.accent.opacity(0.8))
                .frame(width: max(8, geo.size.width * progress), height: 2)
                .opacity(loading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: progress)
                .animation(.easeOut(duration: 0.4), value: loading)
        }
        .frame(height: 2)
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    let controller: BrowserWindowController
    let favorites: [BrowserTab]
    let selectedID: UUID?
    let palette: ThemePalette

    var body: some View {
        let columns = favorites.count <= 3 ? max(favorites.count, 1) : 4
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.favoriteGap), count: columns),
                  spacing: Metrics.favoriteGap) {
            ForEach(favorites) { tab in
                FavoriteTile(controller: controller, tab: tab, selected: tab.id == selectedID, palette: palette)
            }
        }
    }
}

private struct FavoriteTile: View {
    let controller: BrowserWindowController
    let tab: BrowserTab
    let selected: Bool
    let palette: ThemePalette

    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.favoriteRadius, style: .continuous)
            .fill(selected ? palette.activeTab : (hovering ? palette.wellHover : palette.well))
            .overlay {
                FaviconView(url: tab.faviconURL, pageURL: tab.url ?? tab.pinnedURL, title: tab.displayTitle, size: 17)
            }
            .frame(height: Metrics.favoriteHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { controller.select(tab) }
            .pressScale(0.93)
            .animation(Motion.snappy, value: selected)
            .help(tab.displayTitle)
            .contextMenu {
                Button("Copy Link") { controller.copy(tab.url) }
                Button("Reset to Original URL") { controller.resetToPinnedURL(tab) }
                Divider()
                Button("Remove from Favorites") { controller.removeFromFavorites(tab) }
            }
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    let controller: BrowserWindowController
    let model: BrowserModel
    let state: WindowState
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 0) {
            LibraryButton(controller: controller, palette: palette, progress: controller.app.downloads.store.activeFraction)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceDot(space: space, index: index, current: space.id == state.spaceID, palette: palette) {
                        controller.switchToSpace(space)
                    }
                    .contextMenu { SpaceMenu(controller: controller, space: space) }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("New Tab") { controller.newTab(nil) }
                Button("New Folder") { controller.newFolder(nil) }
                Divider()
                Button("New Space") { controller.newSpace(nil) }
            } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(palette.icon)
            }
            .menuStyle(.button)
            .buttonStyle(PressableStyle(scale: 0.86))
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
        }
        .frame(height: Metrics.footerHeight)
    }
}

/// Bottom-left Library entry; doubles as a download progress ring (Arc behaviour).
private struct LibraryButton: View {
    let controller: BrowserWindowController
    let palette: ThemePalette
    let progress: Double?

    var body: some View {
        IconButton(symbol: "archivebox", palette: palette, size: 13, help: "Library (⇧⌘L)") { controller.toggleLibrary(nil) }
            .overlay {
                if let progress {
                    ZStack {
                        Circle().stroke(palette.icon.opacity(0.18), lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.04, progress))
                            .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct SpaceDot: View {
    let space: Space
    let index: Int
    let current: Bool
    let palette: ThemePalette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = space.icon, !icon.isEmpty {
                    Text(icon)
                        .font(.system(size: 13))
                        .saturation(current ? 1 : 0)
                        .opacity(current ? 1 : (hovering ? 0.8 : 0.5))
                } else {
                    Circle()
                        .fill(palette.ink.opacity(current ? 0.6 : 0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(hovering ? palette.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.8))
        .onHover { hovering = $0 }
        .help(index < 9 ? "\(space.title)  ⌃\(index + 1)" : space.title)
    }
}

/// Rename / icon / theme / delete for a Space (header "…", footer right-click, Spaces menu).
struct SpaceMenu: View {
    let controller: BrowserWindowController
    let space: Space

    var body: some View {
        Button("Rename Space") { controller.beginRenameSpace(space) }
        Button("Change Icon…") { controller.editSpace(space, panel: .icon) }
        Button("Edit Theme…") { controller.editSpace(space, panel: .theme) }
        Menu("Profile") {
            ForEach(controller.model.profiles, id: \.self) { profile in
                Toggle(BrowserWindowController.profileName(profile), isOn: Binding(
                    get: { space.profile == profile }, set: { if $0 { controller.setProfile(profile, for: space) } }))
            }
            Divider()
            Button("New Profile…") { controller.newProfile(for: space) }
        }
        Divider()
        Button("Delete Space…") { controller.confirmDelete(space) }
            .disabled(controller.model.spaces.count <= 1)
    }
}
