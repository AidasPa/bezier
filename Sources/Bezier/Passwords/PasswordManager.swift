import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// Saved passwords in pages: suggestions under a focused login field (click, or arrows and
/// Return), and an offer to save or update a password after a login form is sent.
@MainActor
final class PasswordManager: CredentialProvider {
    let vault: PasswordVault
    private let settings: BrowserSettings
    private let panel = AutofillPanel()
    private weak var content: (any WebContent)?
    private var field: LoginField?
    private var mouseMonitor: Any?
    private var savePopover: NSPopover?
    /// Opens Settings › Passwords.
    var onManage: (() -> Void)?

    init(settings: BrowserSettings, vault: PasswordVault = PasswordVault(keyStore: KeychainVaultKeyStore())) {
        self.settings = settings
        self.vault = vault
        panel.model.onPick = { [weak self] login in self?.fill(login) }
        panel.model.onManage = { [weak self] in
            self?.hideSuggestions()
            self?.onManage?()
        }
    }

    // MARK: Suggestions

    func content(_ content: any WebContent, didFocus field: LoginField) {
        guard settings.autofillPasswords, let origin = PasswordVault.origin(of: field.origin), let window = content.view.window else { return }
        var logins = vault.logins(for: origin)
        if field.kind == .username, !field.typed.isEmpty {
            logins = logins.filter { $0.username.localizedCaseInsensitiveContains(field.typed) }
        }
        guard !logins.isEmpty else { hideSuggestions(); return }
        self.content = content
        self.field = field
        let anchor = field.frame.map { window.convertToScreen(content.view.convert($0, to: nil)) }
            ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        panel.model.logins = logins
        panel.model.highlighted = nil
        panel.show(below: anchor, in: window)
        field.showSuggestions(.visible)
        watchClicksOutside()
    }

    func content(_ content: any WebContent, didPress key: LoginField.Key, in _: LoginField) {
        guard panel.isVisible, let field, content === self.content else { return }
        let count = panel.model.logins.count
        switch key {
        case .down: panel.model.highlighted = min((panel.model.highlighted ?? -1) + 1, count - 1)
        case .up: panel.model.highlighted = max((panel.model.highlighted ?? count) - 1, 0)
        case .enter:
            if let i = panel.model.highlighted { fill(panel.model.logins[i]) }
            return
        case .escape:
            hideSuggestions()
            return
        }
        field.showSuggestions(panel.model.highlighted == nil ? .visible : .highlighted)
    }

    func contentDidLeaveLoginField(_ content: any WebContent) {
        if content === self.content { hideSuggestions() }
    }

    private func fill(_ login: SavedLogin) {
        guard let field else { return }
        hideSuggestions()
        // The first fill after launch may show the keychain prompt for Bezier's own key.
        guard let password = try? vault.password(for: login) else { return }
        field.fill(username: login.username, password: password)
        vault.markUsed(login)
    }

    private func hideSuggestions() {
        panel.hide()
        field?.showSuggestions(.hidden)
        field = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// Clicking anywhere but the list (another tab, the sidebar, the page) closes it.
    private func watchClicksOutside() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                // A click back into the same field re-shows the list through the page's own report.
                self.hideSuggestions()
            }
            return event
        }
    }

    // MARK: Saving

    func content(_ content: any WebContent, didSubmitUsername username: String, password: String, origin url: URL) {
        guard settings.offerToSavePasswords, let origin = PasswordVault.origin(of: url), !vault.isNeverSave(origin) else { return }
        let result = vault.pendingResult(username: username, password: password, origin: origin)
        guard result != .unchanged else { return }
        showSavePrompt(result, username: username, password: password, origin: origin, in: content.view)
    }

    private func showSavePrompt(_ result: PasswordVault.SaveResult, username: String, password: String, origin: String, in view: NSView) {
        savePopover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        let host = URL(string: origin)?.host() ?? origin
        popover.contentViewController = NSHostingController(rootView: SavePasswordPrompt(
            host: host, username: username, isUpdate: result == .updated,
            save: { [weak self, weak popover] username in
                _ = try? self?.vault.save(username: username, password: password, origin: origin)
                popover?.close()
            },
            never: { [weak self, weak popover] in
                self?.vault.setNeverSave(origin)
                popover?.close()
            },
            dismiss: { [weak popover] in popover?.close() }))
        guard view.window != nil else { return }
        // Just under the top-right corner of the page.
        let y = view.isFlipped ? 0 : view.bounds.maxY - 1
        popover.show(relativeTo: NSRect(x: view.bounds.maxX - 44, y: y, width: 1, height: 1), of: view,
                     preferredEdge: view.isFlipped ? .minY : .maxY)
        savePopover = popover
    }
}

// MARK: - Suggestion list

@MainActor
@Observable
final class AutofillModel {
    var logins: [SavedLogin] = []
    var highlighted: Int?
    @ObservationIgnored var onPick: ((SavedLogin) -> Void)?
    @ObservationIgnored var onManage: (() -> Void)?
}

/// Borderless list under the field. Never becomes key, so the page keeps focus and typing.
final class AutofillPanel: NSPanel {
    let model = AutofillModel()
    private static let shadowRoom: CGFloat = 14

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        level = .popUpMenu
        let host = NSHostingView(rootView: AutofillList(model: model).padding(Self.shadowRoom))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `anchor` is the field in screen coordinates.
    func show(below anchor: NSRect, in window: NSWindow) {
        let room = Self.shadowRoom
        let width = min(420, max(260, anchor.width)) + room * 2
        contentView?.layoutSubtreeIfNeeded()
        let height = (contentView?.fittingSize.height ?? 100)
        var frame = NSRect(x: anchor.minX - room, y: anchor.minY - 4 - height + room, width: width, height: height)
        if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
            frame.origin.y = anchor.maxY + 4 - room                  // no room below: above the field
        }
        setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

private struct AutofillList: View {
    let model: AutofillModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.logins.prefix(6).enumerated()), id: \.element.id) { index, login in
                Button { model.onPick?(login) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.username.isEmpty ? "No username" : login.username)
                                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("•••••••• · \(login.host)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(model.highlighted == index ? Color.accentColor.opacity(0.18) : .clear))
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.highlighted = index } }
            }
            Divider().padding(.vertical, 3).padding(.horizontal, 6)
            Button { model.onManage?() } label: {
                Text("Manage Passwords…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .modifier(GlassPanel(cornerRadius: 12))
    }
}

// MARK: - Save prompt

private struct SavePasswordPrompt: View {
    let host: String
    @State var username: String
    let isUpdate: Bool
    let save: (String) -> Void
    let never: () -> Void
    let dismiss: () -> Void

    init(host: String, username: String, isUpdate: Bool, save: @escaping (String) -> Void,
         never: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.host = host
        _username = State(initialValue: username)
        self.isUpdate = isUpdate
        self.save = save
        self.never = never
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUpdate ? "Update password?" : "Save password?").font(.system(size: 13, weight: .semibold))
                    Text(host).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if !isUpdate {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
            } else if !username.isEmpty {
                Text(username).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            HStack {
                if !isUpdate { Button("Never") { never() } }
                Spacer()
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isUpdate ? "Update" : "Save") { save(username) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 290)
    }
}
