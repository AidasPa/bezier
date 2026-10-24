import AppKit
import BezierCore
import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case spaces, downloads, archive, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaces: "Spaces"
        case .downloads: "Downloads"
        case .archive: "Archived Tabs"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .spaces: "square.stack"
        case .downloads: "arrow.down.circle"
        case .archive: "archivebox"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Arc's Library: the sidebar widens into a section rail plus a searchable list, while the page
/// stays visible. Back arrow (or Esc) returns to tabs.
struct LibraryView: View {
    let controller: BrowserWindowController
    let state: WindowState
    let palette: ThemePalette

    @State private var query = ""
    @State private var spaceFilter: UUID?
    @FocusState private var searchFocused: Bool

    private var section: LibrarySection { state.librarySection }

    var body: some View {
        HStack(spacing: 0) {
            rail
            VStack(spacing: 10) {
                searchRow
                content
            }
            .padding(.trailing, 2)
        }
        .onChange(of: section) { query = ""; spaceFilter = nil }
        .onExitCommand { controller.closeLibrary() }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: Metrics.toolbarHeight + 8)
            ForEach(LibrarySection.allCases) { item in
                Button { withAnimation(Motion.snappy) { state.librarySection = item } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 17, weight: .regular))
                        Text(item.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(item == section ? palette.ink : palette.inkSecondary)
                    .frame(width: 76, height: 62)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(item == section ? palette.activeTab : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            HStack {
                IconButton(symbol: "arrow.left", palette: palette, help: "Back to Tabs (Esc)") { controller.closeLibrary() }
                Spacer()
            }
            .frame(height: Metrics.footerHeight)
        }
        .frame(width: 84)
        .padding(.trailing, 6)
    }

    // MARK: Search + filter

    private var searchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.icon)
                TextField("Search \(section.title)…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.well))
            if section == .archive {
                Menu {
                    Button("All Spaces") { spaceFilter = nil }
                    Divider()
                    ForEach(controller.model.spaces) { space in
                        Button("\(space.icon ?? "") \(space.title)") { spaceFilter = space.id }
                    }
                } label: {
                    Image(systemName: spaceFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(palette.icon)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Filter by Space")
            }
        }
        .padding(.top, Metrics.toolbarHeight + 8)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch section {
        case .archive: archiveList
        case .history: historyList
        case .downloads: downloadsList
        case .spaces: spacesList
        }
    }

    private var archiveList: some View {
        let items = controller.model.archive.filter { item in
            (spaceFilter == nil || item.spaceID == spaceFilter) && matches(item.title, item.url)
        }
        return GroupedList(items: items, date: \.archivedAt, palette: palette, empty: "No archived tabs") { item in
            LibraryRow(title: item.title ?? URLInput.displayHost(item.url), subtitle: URLInput.displayHost(item.url),
                       faviconURL: item.faviconURL, pageURL: item.url, palette: palette)
                .onTapGesture { controller.restoreArchived(item) }
                .contextMenu {
                    Button("Restore Tab") { controller.restoreArchived(item) }
                    Button("Copy Link") { controller.copy(item.url) }
                    Divider()
                    Button("Delete from Archive") { controller.model.archive.removeAll { $0.id == item.id }; controller.model.didChange() }
                }
        } footer: {
            if !controller.model.archive.isEmpty {
                Button("Clear Archive") { controller.clearArchive() }.buttonStyle(.link).font(.system(size: 11.5))
            }
        }
    }

    private var historyList: some View {
        let items = query.isEmpty ? Array(controller.app.history.recent.prefix(400))
                                  : controller.app.history.search(query, limit: 200).map(\.entry)
        return GroupedList(items: items, date: \.lastVisit, palette: palette, empty: "No history yet") { entry in
            LibraryRow(title: entry.title ?? URLInput.displayHost(entry.url), subtitle: URLInput.displayHost(entry.url),
                       faviconURL: entry.faviconURL, pageURL: entry.url, palette: palette)
                .onTapGesture { controller.openInNewTab(entry.url) }
                .contextMenu {
                    Button("Open in New Tab") { controller.openInNewTab(entry.url) }
                    Button("Copy Link") { controller.copy(entry.url) }
                    Divider()
                    Button("Delete from History") { controller.app.history.remove(entry) }
                }
        } footer: {
            if !controller.app.history.entries.isEmpty {
                Button("Clear History…") { controller.confirmClearHistory() }.buttonStyle(.link).font(.system(size: 11.5))
            }
        }
    }

    private var downloadsList: some View {
        let items = controller.app.downloads.store.items.filter { matches($0.filename, $0.sourceURL) }
        return GroupedList(items: items, date: \.startedAt, palette: palette, empty: "Downloads from the web show up here") { item in
            DownloadRow(item: item, palette: palette)
                .onTapGesture { if let url = item.fileURL, item.state == .completed { NSWorkspace.shared.open(url) } }
                .contextMenu {
                    if item.state == .inProgress { Button("Cancel Download") { item.cancelHandler?() } }
                    if let url = item.fileURL, item.state == .completed {
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Copy Download Link") { controller.copy(item.sourceURL) }
                    Divider()
                    Button("Remove from List") { controller.app.downloads.store.remove(item) }
                }
        } footer: { EmptyView() }
    }

    private var spacesList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(controller.model.spaces.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { space in
                    SpaceCard(space: space, palette: palette, current: space.id == state.spaceID)
                        .onTapGesture { controller.switchToSpace(space) }
                        .pressScale()
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func matches(_ title: String?, _ url: URL?) -> Bool {
        guard !query.isEmpty else { return true }
        return (title ?? "").localizedCaseInsensitiveContains(query) || (url?.absoluteString ?? "").localizedCaseInsensitiveContains(query)
    }
}

/// Items bucketed into Today / Yesterday / weekday / date headers.
private struct GroupedList<Item: Identifiable, Row: View, Footer: View>: View {
    let items: [Item]
    let date: KeyPath<Item, Date>
    let palette: ThemePalette
    let empty: String
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Spacer().frame(height: 40)
                Text(empty).font(.system(size: 12)).foregroundStyle(palette.inkSecondary).multilineTextAlignment(.center)
                footer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.muted)
                            .padding(.leading, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(group.items) { row($0) }
                    }
                    footer().padding(.top, 12).padding(.leading, 8)
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }

    private var groups: [(title: String, items: [Item])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let d = item[keyPath: date]
            let title: String
            if calendar.isDateInToday(d) { title = "Today" }
            else if calendar.isDateInYesterday(d) { title = "Yesterday" }
            else if let days = calendar.dateComponents([.day], from: d, to: .now).day, days < 7 {
                title = d.formatted(.dateTime.weekday(.wide))
            } else {
                title = d.formatted(.dateTime.month(.wide).day().year())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(item)
        }
        return order.map { ($0, buckets[$0]!) }
    }
}

private struct LibraryRow: View {
    let title: String
    let subtitle: String
    let faviconURL: URL?
    let pageURL: URL?
    let palette: ThemePalette

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(url: faviconURL, pageURL: pageURL, title: title)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pressScale()
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let palette: ThemePalette

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
                    .truncationMode(.middle)
                switch item.state {
                case .inProgress:
                    ProgressView(value: item.fraction).progressViewStyle(.linear).controlSize(.mini).tint(palette.accent)
                case .completed:
                    Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) + " · " + URLInput.displayHost(item.sourceURL))
                        .font(.system(size: 11)).foregroundStyle(palette.inkSecondary).lineLimit(1)
                case .failed:
                    Text("Failed").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
                case .cancelled:
                    Text("Cancelled").font(.system(size: 11)).foregroundStyle(palette.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            if item.state == .inProgress {
                Button { item.cancelHandler?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.icon) }
                    .buttonStyle(PressableStyle())
            } else if hovering, let url = item.fileURL, item.state == .completed {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(palette.icon)
                }
                .buttonStyle(PressableStyle())
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { item.fileURL.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() } ?? NSItemProvider() }
    }

    private var icon: NSImage {
        if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

private struct SpaceCard: View {
    let space: Space
    let palette: ThemePalette
    let current: Bool

    var body: some View {
        let theme = ThemePalette(theme: space.theme, systemIsDark: palette.isDark)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: theme.frameColors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .overlay(Text(space.icon ?? "").font(.system(size: 16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(space.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                Text("\(space.allPinnedTabs.count) pinned · \(space.today.count) today")
                    .font(.system(size: 11)).foregroundStyle(palette.inkSecondary)
            }
            Spacer()
            if current { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.icon) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current ? palette.activeTab : palette.well))
        .contentShape(Rectangle())
    }
}
