import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// ⌘, Settings: General · Spaces · Passwords · Shortcuts · Import · Advanced, as standard macOS
/// toolbar tabs.
/// Every control here changes real behaviour; nothing is decorative.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    enum Pane: Int { case general, spaces, passwords, shortcuts, importer, advanced }

    static func show(app: AppContext, pane: Pane? = nil) {
        let controller = shared ?? SettingsWindowController(app: app)
        shared = controller
        if let pane, let tabs = controller.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = pane.rawValue
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(app: AppContext) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func pane(_ title: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            host.title = title // the toolbar-style tab controller shows this as the window title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(pane("General", "gearshape", GeneralPane(app: app, settings: app.settings, model: app.model)))
        tabs.addTabViewItem(pane("Spaces", "square.stack", SpacesPane(app: app, model: app.model)))
        tabs.addTabViewItem(pane("Passwords", "key", PasswordsPane(settings: app.settings, vault: app.passwords.vault)))
        tabs.addTabViewItem(pane("Shortcuts", "keyboard", ShortcutsPane(store: app.shortcuts)))
        tabs.addTabViewItem(pane("Import", "square.and.arrow.down", ImportPane(app: app)))
        tabs.addTabViewItem(pane("Advanced", "slider.horizontal.3", AdvancedPane(app: app)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - General

private struct GeneralPane: View {
    let app: AppContext
    @Bindable var settings: BrowserSettings
    let model: BrowserModel

    @State private var isDefault = false

    private static let archiveOptions: [(String, TimeInterval)] = [
        ("12 hours", 12 * 3600), ("24 hours", 24 * 3600), ("7 days", 7 * 86_400), ("30 days", 30 * 86_400), ("Never", 0),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Default browser") {
                    if isDefault {
                        Label("Bezier is your default browser", systemImage: "checkmark.seal.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") {
                            Task {
                                await settings.makeDefaultBrowser()
                                isDefault = settings.isDefaultBrowser
                            }
                        }
                    }
                }
            }
            Section("Command Bar") {
                Picker("Search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle(isOn: $settings.showSearchSuggestions) {
                    Text("Show search suggestions")
                    Text("What you type is sent to \(settings.searchEngine.name) as you type.")
                }
                .disabled(settings.searchEngine.suggestTemplate == nil)
                Toggle(isOn: $settings.showTimeConversions) {
                    Text("Convert times between time zones")
                    Text("Type “4pm utc” or “9am pst to tokyo”.")
                }
            }
            Section("Onboarding") {
                LabeledContent("Welcome tour") {
                    Button("Show Onboarding") { app.activeWindow?.showOnboarding(nil) }
                }
            }
            Section("Appearance") {
                Picker("Websites use", selection: $settings.websiteAppearance) {
                    ForEach(BrowserSettings.WebsiteAppearance.allCases) { Text($0.title).tag($0) }
                }
                Text("Space colours and light/dark are set per Space: hover the Space name and click the brush.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sidebar") {
                Toggle("Show full URL in the address pill", isOn: $settings.showFullURL)
                Toggle(isOn: $settings.openLinksInPeek) {
                    Text("Open links from pinned tabs and Favorites in Peek")
                    Text("Links to other sites preview on top of the page instead of leaving it.")
                }
                Picker("Archive unpinned tabs after", selection: Binding(
                    get: { model.autoArchiveAfter },
                    set: { model.autoArchiveAfter = $0; model.didChange() }
                )) {
                    ForEach(Self.archiveOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            Section {
                ForEach($settings.linkRoutes) { $route in
                    HStack {
                        TextField("Site", text: $route.site, prompt: Text("figma.com"))
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("Space", selection: $route.spaceID) {
                            ForEach(model.spaces) { space in Text("\(space.icon.map { "\($0) " } ?? "")\(space.title)").tag(space.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { settings.linkRoutes.removeAll { $0.id == route.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove Rule")
                    }
                }
                Button("Add Rule") {
                    settings.linkRoutes.append(LinkRoute(site: "", spaceID: app.activeWindow?.currentSpace.id ?? model.spaces[0].id))
                }
            } header: {
                Text("Air Traffic Control")
            } footer: {
                Text("Links from other apps open in a Mini Bezier window, unless their site has a rule here.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { isDefault = settings.isDefaultBrowser }
    }
}

// MARK: - Spaces

private struct SpacesPane: View {
    let app: AppContext
    let model: BrowserModel

    var body: some View {
        Form {
            Section {
                ForEach(model.spaces) { space in
                    SpaceSettingsRow(app: app, model: model, space: space)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("New Space") {
                        let theme = SpaceTheme.newSpaceDefault(index: model.spaces.count)
                        model.newSpace(title: "Space \(model.spaces.count + 1)", theme: theme)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 260)
    }
}

private struct SpaceSettingsRow: View {
    let app: AppContext
    let model: BrowserModel
    let space: Space

    @State private var name = ""
    @State private var pickingIcon = false

    var body: some View {
        HStack(spacing: 12) {
            Button { pickingIcon = true } label: {
                Text(space.icon ?? "◌").font(.system(size: 18)).frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(PressableStyle(scale: 0.85))
            .popover(isPresented: $pickingIcon) {
                IconPicker(current: space.icon) { icon in
                    model.setIcon(icon, for: space)
                    pickingIcon = false
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { model.rename(space, to: name) }
                .onAppear { name = space.title }
            Spacer()
            Menu {
                ForEach(model.profiles, id: \.self) { profile in
                    Button(BrowserWindowController.profileName(profile)) { app.activeWindow?.setProfile(profile, for: space) }
                }
                Divider()
                Button("New Profile…") { app.activeWindow?.newProfile(for: space) }
            } label: {
                Label(BrowserWindowController.profileName(space.profile), systemImage: "person.crop.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Profile: cookies and site data for this Space")
            HStack(spacing: 5) {
                ForEach(SpaceTheme.named, id: \.0) { title, theme in
                    let palette = ThemePalette(theme: theme, systemIsDark: false)
                    let swatch = theme.isNeutral ? [Color(white: 0.92), palette.accent] : palette.frameColors.map { Color(nsColor: $0) }
                    Button { app.activeWindow?.setTheme(theme, for: space) ?? { space.theme = theme; model.didChange() }() } label: {
                        Circle().fill(LinearGradient(colors: swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .overlay {
                                if space.theme == theme {
                                    Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.35), radius: 1)
                                }
                            }
                            .scaleEffect(space.theme == theme ? 1.15 : 1)
                    }
                    .buttonStyle(PressableStyle(scale: 0.8))
                    .help(title)
                }
            }
            Button {
                if let window = app.activeWindow { window.confirmDelete(space) } else { model.delete(space) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .disabled(model.spaces.count <= 1)
            .help("Delete Space")
        }
    }
}

// MARK: - Shortcuts

/// Generated from the menu bar, so it always matches what's bound.
// MARK: - Import

/// Copies Spaces, pinned tabs and folders, open tabs, Favorites, history and saved passwords
/// from Arc. Reads Arc's files only; importing again won't duplicate anything.
private struct ImportPane: View {
    let app: AppContext
    @State private var from: ImportSource? = ArcImporter.isInstalled ? nil : ImportSource.installed.first

    var body: some View {
        VStack(spacing: 0) {
            if !ImportSource.installed.isEmpty {
                Picker("Import from", selection: $from) {
                    Text("Arc").tag(ImportSource?.none)
                    ForEach(ImportSource.installed) { Text($0.name).tag(ImportSource?.some($0)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .frame(width: 520)
            }
            if let from {
                BrowserImportPane(app: app, source: from).id(from)
            } else {
                ArcImportPane(app: app)
            }
        }
    }
}

/// Bookmarks, history and (Chromium browsers) passwords from another browser.
private struct BrowserImportPane: View {
    let app: AppContext
    let source: ImportSource

    @State private var bookmarks = true
    @State private var history = true
    @State private var passwords = true
    @State private var preview: BrowserImport?
    @State private var failed = false
    @State private var importing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                if let preview {
                    Text("Found \(preview.bookmarkCount.formatted()) bookmarks").font(.callout)
                } else if failed {
                    Label(source == .safari ? "Bezier can't read Safari's files. Allow it in System Settings › Privacy & Security › Full Disk Access, then try again."
                                            : "No \(source.name) data found.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Import from \(source.name)")
            }
            Section("What to import") {
                Toggle(isOn: $bookmarks) {
                    Text("Bookmarks")
                    Text("Into a “From \(source.name)” folder in the current Space's pinned tabs.")
                }
                Toggle("Browsing history", isOn: $history)
                if source.hasPasswords {
                    Toggle(isOn: $passwords) {
                        Text("Saved passwords")
                        Text("macOS asks once for access to “\(source.chromium?.service ?? "")”.")
                    }
                }
            }
            Section {
                HStack {
                    if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).font(.callout) }
                    Spacer()
                    if importing { ProgressView().controlSize(.small) }
                    Button("Import from \(source.name)") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || importing || !(bookmarks || history || (passwords && source.hasPasswords)))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let source = source
            preview = await Task.detached { try? BrowserImporter.load(source, includeHistory: false) }.value
            failed = preview == nil
        }
    }

    private func run() {
        importing = true
        Task {
            if let s = await app.importFrom(source, bookmarks: bookmarks, history: history, passwords: passwords && source.hasPasswords) {
                var parts = ["\(s.bookmarks) bookmarks"]
                if s.historyEntries > 0 { parts.append("\(s.historyEntries.formatted()) history pages") }
                if s.passwords > 0 { parts.append("\(s.passwords) passwords") }
                if s.passwordsFailed > 0 { parts.append("\(s.passwordsFailed) passwords couldn't be read") }
                result = "Imported " + parts.joined(separator: " · ")
            } else {
                result = "Nothing could be read."
            }
            importing = false
        }
    }
}

private struct ArcImportPane: View {
    let app: AppContext

    @State private var source: URL = ArcImporter.arcDirectory
    @State private var preview: ArcImport?
    @State private var passwordCount = 0
    @State private var failed = false
    @State private var options = ArcImportOptions()
    @State private var importing = false
    @State private var summary: ArcImportSummary?

    var body: some View {
        Form {
            Section {
                LabeledContent("Source") {
                    HStack {
                        Text(source.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                if let preview {
                    Text("Found " + [plural(preview.spaces.count, "Space"), plural(preview.pinnedTabCount, "pinned tab"),
                                     plural(preview.folderCount, "folder"), plural(preview.todayTabCount, "open tab"),
                                     plural(preview.favorites.count, "Favorite"), plural(passwordCount, "password")]
                        .joined(separator: " · "))
                        .font(.callout)
                } else if failed {
                    Label("No Arc data found here. Pick Arc's data folder (~/Library/Application Support/Arc).", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Import from Arc")
            } footer: {
                Text("Arc stops working on December 22, 2026. Bring your setup over before then.")
            }

            Section("What to import") {
                Toggle("Spaces, pinned tabs and folders", isOn: $options.spaces)
                Toggle("Open tabs (Today)", isOn: $options.todayTabs).disabled(!options.spaces)
                Toggle("Favorites", isOn: $options.favorites)
                Toggle("Browsing history", isOn: $options.history)
                Toggle(isOn: $options.passwords) {
                    Text("Saved passwords")
                    Text("macOS asks once for access to “Arc Safe Storage”, the key Arc encrypts them with.")
                }
            }

            Section {
                HStack {
                    if let summary {
                        Label(describe(summary), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    if importing { ProgressView().controlSize(.small) }
                    Button("Import from Arc") { runImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || importing)
                }
            } footer: {
                Text("Cookies and extensions can't be copied, so you'll sign in to sites again (saved passwords fill in).")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: source) { loadPreview() }
    }

    private func loadPreview() {
        do {
            preview = try ArcImporter.load(includeHistory: false, from: source)
            passwordCount = ArcPasswords.count(userData: source.appending(path: "User Data", directoryHint: .isDirectory))
            failed = false
        } catch {
            preview = nil
            failed = true
        }
    }

    private func runImport() {
        importing = true
        Task {
            summary = await app.importFromArc(source, options: options)
            importing = false
        }
    }

    private func describe(_ s: ArcImportSummary) -> String {
        var parts: [String] = []
        if s.spacesAdded > 0 { parts.append(plural(s.spacesAdded, "new Space")) }
        if s.spacesMerged > 0 { parts.append("\(s.spacesMerged) merged") }
        parts.append(plural(s.pinnedTabs + s.todayTabs, "tab"))
        if s.folders > 0 { parts.append(plural(s.folders, "folder")) }
        if s.favorites > 0 { parts.append(plural(s.favorites, "Favorite")) }
        if s.historyEntries > 0 { parts.append(plural(s.historyEntries, "history page")) }
        if s.passwords > 0 { parts.append(plural(s.passwords, "password")) }
        if s.passwordsFailed > 0 { parts.append("\(plural(s.passwordsFailed, "password")) couldn't be read") }
        return "Imported " + parts.joined(separator: " · ")
    }

    private func plural(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = source
        panel.message = "Choose Arc's data folder (it contains StorableSidebar.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    let app: AppContext
    @State private var downloads: URL = .downloadsDirectory
    @State private var status: String?

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text(downloads.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { chooseFolder() }
                    }
                }
            }
            Section("Privacy") {
                LabeledContent("History") {
                    Button("Clear History") { app.history.clear(); status = "History cleared." }
                }
                LabeledContent("Archive") {
                    Button("Clear Archive") { app.model.archive.removeAll(); app.model.didChange(); status = "Archive cleared." }
                }
                LabeledContent("Website data") {
                    Button("Clear Cookies & Caches") {
                        Task {
                            let profiles = Set(app.model.spaces.map(\.profile))
                            for profile in profiles { await app.engine.clearWebsiteData(profile: ProfileID(profile)) }
                            status = "Cookies, caches and site storage cleared. You'll be signed out of websites."
                        }
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Data") {
                LabeledContent("Bezier data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserStore.defaultDirectory]) }
                }
                LabeledContent("Engine") { Text(app.engine.name).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { downloads = app.engine.downloadDirectory }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloads
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloads = url
        app.engine.downloadDirectory = url
        app.settings.downloadDirectory = url
    }
}
