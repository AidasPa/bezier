import AppKit
import BezierCore
import Observation
import SwiftUI

/// ⌘T / ⌘L. Appears instantly (Arc removed its entrance animation in v1.3 because it "felt
/// slow"), centred on the window, washes the page behind it, and does search, URLs, tab
/// switching, ~50 actions and time-zone answers.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    enum Mode { case newTab, editCurrent }

    /// Bar layout, shared by the positioning math and the view.
    enum Layout {
        static let width: ClosedRange<CGFloat> = 520...700
        static let inputHeight: CGFloat = 56
        static let rowHeight: CGFloat = 40
        static let maxRows = 8
        static let listPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 24
        /// Transparent margin around the bar so its shadow isn't clipped by the panel.
        /// Big enough that the shadow fully fades before the panel edge (blur + offset < margin).
        static let margin: CGFloat = 90
        /// The bar is centred on the window when it shows this many rows (Arc's resting state);
        /// fewer rows keep the input in place and shrink downward.
        static let referenceRows = 6
    }

    private weak var browser: BrowserWindowController?
    private let panel: CommandBarPanel
    private let model = CommandBarModel()

    init(browser: BrowserWindowController) {
        self.browser = browser
        panel = CommandBarPanel()
        super.init()
        panel.delegate = self
        let host = NSHostingView(rootView: CommandBarView(model: model))
        host.safeAreaRegions = []
        panel.contentView = host
        model.perform = { [weak self] item, modifiers in self?.perform(item, modifiers: modifiers) }
        model.dismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func show(mode: Mode) {
        guard let browser, let window = browser.window else { return }
        model.mode = mode
        model.site = nil
        model.palette = browser.state.palette
        model.sources = CommandBarSources(browser: browser)
        if mode == .editCurrent, let tab = browser.selectedTab, let url = tab.url {
            model.query = url.absoluteString
            model.selectAllOnAppear = true
            model.currentFavicon = (tab.faviconURL, url)
        } else {
            model.query = ""
            model.selectAllOnAppear = false
            model.currentFavicon = nil
        }
        model.refresh()

        // Centre on the whole window (sidebar included), like Arc.
        let frame = window.frame
        let width = min(Layout.width.upperBound, max(Layout.width.lowerBound, frame.width * 0.54))
        let maxBar = Layout.inputHeight + Layout.listPadding * 2 + CGFloat(Layout.maxRows) * Layout.rowHeight
        let referenceBar = Layout.inputHeight + Layout.listPadding * 2 + CGFloat(Layout.referenceRows) * Layout.rowHeight
        let barTop = min(frame.maxY - 60, frame.midY + referenceBar / 2)
        let panelHeight = maxBar + Layout.margin * 2
        let origin = NSPoint(x: frame.midX - width / 2 - Layout.margin, y: barTop + Layout.margin - panelHeight)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width + Layout.margin * 2, height: panelHeight)), display: false)

        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        browser.root.card.setWashed(true)
        model.focusToken += 1
    }

    #if DEBUG
    /// Automation: "tab", "delete" (on an empty field), or nothing; returns what the bar shows.
    func debug(_ key: String) -> String {
        if key == "tab" { model.tab() }
        if key == "delete", model.query.isEmpty { model.site = nil }
        let rows = model.items.prefix(3).map { item -> String in
            if case .open(let url) = item.kind { return "\(item.title) -> \(url.absoluteString)" }
            return item.title
        }
        return "site=\(model.site?.name ?? "-") candidate=\(model.siteCandidate?.name ?? "-") query='\(model.query)' rows=\(rows)"
    }
    #endif

    func setQuery(_ text: String) {
        model.currentFavicon = nil
        model.query = text
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        browser?.root.card.setWashed(false)
        browser?.window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func perform(_ item: CommandBarItem, modifiers: NSEvent.ModifierFlags) {
        guard let browser else { return }
        hide()
        switch item.kind {
        case .open(let url):
            if model.mode == .editCurrent, browser.selectedTab != nil, !modifiers.contains(.command) {
                browser.navigateSelected(to: url)
            } else {
                browser.openInNewTab(url)
            }
        case .switchToTab(let tab):
            browser.select(tab)
        case .action(let action):
            action.run(browser)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            browser.showToast("Copied \(text)", symbol: "clock")
        }
    }
}

/// Borderless panel that can take keyboard focus. Clicks on its transparent margin fall
/// through to the browser window, which dismisses the bar.
final class CommandBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = false
        hidesOnDeactivate = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Model

struct CommandBarItem: Identifiable {
    enum Kind {
        case open(URL)
        case switchToTab(BrowserTab)
        case action(CommandAction)
        case copy(String)
    }

    enum Trailing {
        case none
        case label(String)
        /// Only shown on the selected row ("Google" next to a search).
        case hint(String)
        case switchToTab
        case shortcut(String)
    }

    /// Stable identity ("tab:…", "history:…", "suggest:…") so rows don't flicker when
    /// suggestions arrive and the selection survives re-ranking.
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    var symbol: String?
    var faviconURL: URL?
    var pageURL: URL?
    var trailing: Trailing = .none
    var score = 0
    /// Rich answer rows (time zones) render larger.
    var isAnswer = false
}

/// What the Command Bar searches over, captured when it opens.
@MainActor
struct CommandBarSources {
    var tabs: [(tab: BrowserTab, space: String?)] = []
    var actions: [CommandAction] = []
    var selectedTabID: UUID?
    var history: HistoryStore?
    var engine: SearchEngine = .google
    var showSuggestions = false
    var showTimeConversions = true
    var suggestions: SearchSuggestions?

    init() {}

    init(browser: BrowserWindowController) {
        let model = browser.model
        tabs = model.favorites.map { ($0, nil) }
        for space in model.spaces {
            tabs += space.allPinnedTabs.map { ($0, space.title) }
            tabs += space.today.map { ($0, space.title) }
        }
        actions = CommandActions.available(in: browser)
        selectedTabID = browser.selectedTab?.id
        history = browser.app.history
        let settings = browser.app.settings
        engine = settings.searchEngine
        showSuggestions = settings.showSearchSuggestions && engine.suggestTemplate != nil
        showTimeConversions = settings.showTimeConversions
        suggestions = browser.app.suggestions
    }
}

@MainActor
@Observable
final class CommandBarModel {
    var query = "" { didSet { if query != oldValue { refresh() } } }
    /// Tab to search: queries go to this site until Delete is pressed on an empty field.
    var site: SiteSearch? { didSet { if site != oldValue { refresh() } } }
    /// The site Tab would pick for what's typed.
    var siteCandidate: SiteSearch? { site == nil ? SiteSearch.match(query) : nil }
    var items: [CommandBarItem] = []
    var selection = 0
    var mode: CommandBarController.Mode = .newTab
    var palette = ThemePalette(theme: .lavender, systemIsDark: false)
    var selectAllOnAppear = false
    var focusToken = 0
    /// Favicon for the input row when editing the current tab's URL (⌘L), like Arc.
    var currentFavicon: (url: URL?, page: URL?)?
    @ObservationIgnored var sources = CommandBarSources()
    @ObservationIgnored var perform: ((CommandBarItem, NSEvent.ModifierFlags) -> Void)?
    @ObservationIgnored var dismiss: (() -> Void)?
    @ObservationIgnored private var lastPointer: (row: Int, point: CGPoint)?
    /// Local results for the current query; suggestions are merged into these.
    @ObservationIgnored private var local: [CommandBarItem] = []
    @ObservationIgnored private var lastSuggestions: [String] = []

    private static let maxSuggestions = 4

    /// Everything local (tabs, history, actions, answers) is computed synchronously on every
    /// keystroke; engine suggestions stream in afterwards without moving the selection.
    func refresh() {
        let text = query.trimmingCharacters(in: .whitespaces)
        local = site.map { siteResults(for: text, site: $0) } ?? localResults(for: text)

        var suggestions: [String] = []
        if sources.showSuggestions, !text.isEmpty, URLInput.directURL(text) == nil, let service = sources.suggestions {
            let lower = text.lowercased()
            // Instant: exact cached answer, or previous suggestions that still match what's typed.
            suggestions = service.cached(text, engine: sources.engine)
                ?? lastSuggestions.filter { $0.lowercased().hasPrefix(lower) }
            service.fetch(text, engine: sources.engine) { [weak self] list in
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
                self.lastSuggestions = list
                self.publish(suggestions: list, for: text, keepSelection: true)
            }
        } else {
            sources.suggestions?.cancel()
        }
        publish(suggestions: suggestions, for: text, keepSelection: false)
    }

    private func publish(suggestions: [String], for text: String, keepSelection: Bool) {
        let selectedID = keepSelection && items.indices.contains(selection) ? items[selection].id : nil
        let lower = text.lowercased()
        let extra = suggestions
            .filter { $0.lowercased() != lower }
            .prefix(Self.maxSuggestions)
            .enumerated()
            .map { index, s in
                if let site {
                    return CommandBarItem(id: "suggest:" + s, kind: .open(site.url(for: s)), title: s,
                                          symbol: "magnifyingglass", trailing: .hint(site.name), score: 30 - index)
                }
                return CommandBarItem(id: "suggest:" + s, kind: .open(sources.engine.searchURL(for: s)), title: s,
                                      symbol: "magnifyingglass", trailing: .hint(sources.engine.name), score: 30 - index)
            }
        items = (local + extra).enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
            .prefix(CommandBarController.Layout.maxRows)
            .map { $0 }
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else if !keepSelection {
            selection = 0
            lastPointer = nil
        }
    }

    private func siteResults(for text: String, site: SiteSearch) -> [CommandBarItem] {
        guard !text.isEmpty else { return [] }
        return [CommandBarItem(id: "site:" + text, kind: .open(site.url(for: text)), title: text,
                               subtitle: "Search \(site.name)", pageURL: URL(string: "https://\(site.host)"),
                               trailing: .label(site.name), score: 100)]
    }

    /// Tab: pick the site that matches what's typed; otherwise move down the list.
    func tab() {
        if let candidate = siteCandidate {
            site = candidate
            query = ""
        } else {
            move(1)
        }
    }

    private func localResults(for text: String) -> [CommandBarItem] {
        var result: [CommandBarItem] = []

        if sources.showTimeConversions, let time = TimeZoneQuery.parse(text) {
            result.append(Self.answer(for: time))
        }

        if !text.isEmpty {
            if let url = URLInput.directURL(text) {
                result.append(CommandBarItem(id: "open:" + text, kind: .open(url), title: text, symbol: "globe",
                                             trailing: .label(mode == .editCurrent ? "Open" : "Open in New Tab"), score: 95))
            } else {
                result.append(CommandBarItem(id: "search:" + text, kind: .open(sources.engine.searchURL(for: text)), title: text,
                                             symbol: "magnifyingglass", trailing: .hint(sources.engine.name), score: 62))
            }
        }

        let tabs = sources.tabs.filter { $0.tab.id != sources.selectedTabID }
        if text.isEmpty {
            // Resting state: recently used tabs.
            return result + tabs.sorted { $0.tab.lastActiveAt > $1.tab.lastActiveAt }.prefix(6).map { Self.item(for: $0, score: 0) }
        }

        var openURLs = Set<String>()
        for pair in sources.tabs {
            if let url = pair.tab.url { openURLs.insert(url.absoluteString) }
        }
        for pair in tabs {
            let host = URLInput.displayHost(pair.tab.url ?? pair.tab.pinnedURL)
            var score = CommandMatcher.score(query: text, title: pair.tab.displayTitle, keywords: [host]).map { $0 - 25 }
            if score == nil, text.count >= 2, (pair.tab.url?.absoluteString.lowercased().contains(text.lowercased()) ?? false) {
                score = 50
            }
            if let score { result.append(Self.item(for: pair, score: score)) }
        }

        // History: strong host/title matches can outrank the plain search, like Arc and Chrome.
        if let history = sources.history {
            for (entry, score) in history.search(text, limit: 6) where !openURLs.contains(entry.url.absoluteString) {
                result.append(CommandBarItem(id: "history:" + entry.id, kind: .open(entry.url),
                                             title: entry.title ?? URLInput.displayHost(entry.url),
                                             subtitle: Self.shortURL(entry.url), faviconURL: entry.faviconURL,
                                             pageURL: entry.url, score: 40 + Int(Double(score) * 0.6)))
            }
        }

        for action in sources.actions {
            guard let score = CommandMatcher.score(query: text, title: action.title, keywords: action.keywords) else { continue }
            result.append(CommandBarItem(id: "action:" + action.id, kind: .action(action), title: action.title, symbol: action.symbol,
                                         trailing: action.shortcut.map { .shortcut($0) } ?? .none, score: score))
        }
        return result
    }

    /// "github.com/apple/swift" — scheme and www dropped; the view truncates the middle.
    static func shortURL(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.absoluteString.replacing(#/^https?://(www\.)?/#, with: "").replacing(#/\/$/#, with: "")
    }

    private static func item(for pair: (tab: BrowserTab, space: String?), score: Int) -> CommandBarItem {
        let tab = pair.tab
        let subtitle = [shortURL(tab.url ?? tab.pinnedURL), pair.space].compactMap { $0 }.joined(separator: " · ")
        return CommandBarItem(id: "tab:" + tab.id.uuidString, kind: .switchToTab(tab), title: tab.displayTitle, subtitle: subtitle,
                              faviconURL: tab.faviconURL, pageURL: tab.url ?? tab.pinnedURL, trailing: .switchToTab, score: score)
    }

    /// "7:00 PM EEST" with "4:00 PM UTC → your time (Vilnius)".
    private static func answer(for time: TimeConversion) -> CommandBarItem {
        func clock(_ zone: TimeZone) -> String {
            let f = DateFormatter()
            f.timeZone = zone
            f.timeStyle = .short
            f.dateStyle = .none
            return f.string(from: time.instant)
        }
        func abbreviation(_ zone: TimeZone) -> String {
            // Foundation calls UTC "GMT"; say what the user typed.
            if zone.identifier == "UTC" || zone.identifier == "GMT" { return zone.identifier }
            return zone.abbreviation(for: time.instant) ?? zone.identifier
        }
        func place(_ zone: TimeZone) -> String {
            zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        }
        func day(_ zone: TimeZone) -> String {
            let f = DateFormatter()
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate("EEE d MMM")
            return f.string(from: time.instant)
        }
        /// "PDT" where a real abbreviation exists, otherwise the city ("1:00 AM Tokyo", not "GMT+9").
        func label(_ zone: TimeZone) -> String {
            let abbr = abbreviation(zone)
            return abbr.hasPrefix("GMT") && abbr != "GMT" ? place(zone) : abbr
        }

        let target = time.target
        let title = "\(clock(target)) \(label(target))"
        var subtitle: String
        if time.isNow {
            subtitle = "Now in \(place(target)) · \(day(target))"
        } else {
            let whose = target == .current ? "your time (\(place(target)))" : place(target)
            subtitle = "\(clock(time.source)) \(label(time.source)) → \(whose)"
            if day(target) != day(time.source) { subtitle += " · \(day(target))" }
        }
        return CommandBarItem(id: "time", kind: .copy(title), title: title, subtitle: subtitle, symbol: "clock",
                              trailing: .label("Copy"), score: 110, isAnswer: true)
    }

    func pointerMoved(to point: CGPoint, row: Int) -> Bool {
        defer { lastPointer = (row, point) }
        guard let last = lastPointer else { return false }
        return last.row != row || hypot(last.point.x - point.x, last.point.y - point.y) > 2
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    func commit(modifiers: NSEvent.ModifierFlags = []) {
        guard items.indices.contains(selection) else { return }
        perform?(items[selection], modifiers)
    }
}

// MARK: - View

struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    @FocusState private var focused: Bool

    private typealias L = CommandBarController.Layout

    var body: some View {
        let palette = model.palette
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Group {
                        if let favicon = model.currentFavicon {
                            FaviconView(url: favicon.url, pageURL: favicon.page, title: model.query, size: 18)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 22)
                    if let site = model.site {
                        HStack(spacing: 5) {
                            FaviconView(url: nil, pageURL: URL(string: "https://\(site.host)"), title: site.name, size: 14)
                                .frame(width: 14, height: 14)
                            Text(site.name).font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Capsule().fill(palette.accent.opacity(0.16)))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    TextField(model.site.map { "Search \($0.name)…" } ?? "Search or Enter URL…", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19))
                        .focused($focused)
                        .onSubmit { model.commit(modifiers: NSEvent.modifierFlags) }
                        .onKeyPress(.upArrow) { model.move(-1); return .handled }
                        .onKeyPress(.downArrow) { model.move(1); return .handled }
                        .onKeyPress(.escape) {
                            if model.site != nil { model.site = nil } else { model.dismiss?() }
                            return .handled
                        }
                        .onKeyPress(.tab) { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { model.tab() }; return .handled }
                        .onKeyPress(.delete) {
                            guard model.query.isEmpty, model.site != nil else { return .ignored }
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { model.site = nil }
                            return .handled
                        }
                    if let candidate = model.siteCandidate {
                        HStack(spacing: 6) {
                            Text("Search \(candidate.name)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Text("tab").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                        }
                        .fixedSize()
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: L.inputHeight)

                if !model.items.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 14)
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            CommandBarRow(item: item, selected: index == model.selection, accent: palette.accent)
                                .onTapGesture { model.selection = index; model.commit() }
                                .onContinuousHover { phase in
                                    // Only real mouse movement moves the selection, not where the
                                    // pointer happened to rest when the bar opened.
                                    if case .active(let point) = phase, model.pointerMoved(to: point, row: index) {
                                        model.selection = index
                                    }
                                }
                        }
                    }
                    .padding(L.listPadding)
                }
            }
            .modifier(GlassPanel(cornerRadius: L.cornerRadius))
            .padding(L.margin)
            Spacer(minLength: 0)
        }
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .onChange(of: model.focusToken, initial: true) {
            focused = true
            if model.selectAllOnAppear {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
    }
}

private struct CommandBarRow: View {
    let item: CommandBarItem
    let selected: Bool
    let accent: Color

    private var radius: CGFloat {
        // Concentric with the panel: outer radius minus the list inset.
        CommandBarController.Layout.cornerRadius - CommandBarController.Layout.listPadding
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                } else {
                    FaviconView(url: item.faviconURL, pageURL: item.pageURL, title: item.title)
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.white : .clear))
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(selected ? Color.white : Color.secondary)

            if item.isAnswer {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.system(size: 15, weight: .semibold))
                    if let subtitle = item.subtitle { Text(subtitle).font(.system(size: 11.5)).opacity(0.7) }
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
            } else {
                HStack(spacing: 0) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(" — " + subtitle).font(.system(size: 13.5)).opacity(0.55)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: CommandBarController.Layout.rowHeight)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? accent : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        switch item.trailing {
        case .none:
            EmptyView()
        case .label(let text):
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
        case .hint(let text):
            if selected {
                Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.9))
            }
        case .switchToTab:
            HStack(spacing: 6) {
                Text("Switch to Tab").font(.system(size: 11.5, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.95) : Color.primary.opacity(0.08)))
                    .foregroundStyle(selected ? accent : Color.secondary)
            }
            .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
        case .shortcut(let keys):
            Keycaps(keys: keys, selected: selected)
        }
    }
}

/// "⇧⌘C" rendered as individual keycaps.
private struct Keycaps: View {
    let keys: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(String(key))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07)))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.secondary)
    }
}

/// Liquid Glass on macOS 26 (floating control layer, per Apple's guidelines), with a vibrant
/// material fallback on earlier systems.
struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                .shadow(color: .black.opacity(0.16), radius: 36, y: 18)
        } else {
            content
                .background(VisualEffectBackground(material: .popover))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                .shadow(color: .black.opacity(0.18), radius: 36, y: 18)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
