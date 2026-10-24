import AppKit
import BezierCore
import LocalAuthentication
import SwiftUI

/// Settings › Passwords: autofill switches, saved logins (search, reveal, copy, delete) and
/// sites set to never save. Revealing or copying a password asks for Touch ID or the Mac's
/// password, then stays unlocked for five minutes.
struct PasswordsPane: View {
    @Bindable var settings: BrowserSettings
    let vault: PasswordVault

    @State private var search = ""
    @State private var revealed: Set<UUID> = []
    @State private var unlockedUntil: Date?
    @State private var pendingDelete: SavedLogin?
    @State private var status: String?

    private var filtered: [SavedLogin] {
        let sorted = vault.logins.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.host.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Fill saved passwords", isOn: $settings.autofillPasswords)
                Toggle("Offer to save passwords", isOn: $settings.offerToSavePasswords)
            } footer: {
                Text("Passwords are encrypted with a key kept in your login keychain.")
            }

            Section {
                if vault.logins.isEmpty {
                    Text("No saved passwords yet. Import them from Arc in Settings › Import, or sign in to a site and choose Save.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    TextField("Search", text: $search, prompt: Text("Search sites and usernames"))
                    ForEach(filtered) { login in row(login) }
                }
            } header: {
                Text(vault.logins.count == 1 ? "1 saved password" : "\(vault.logins.count) saved passwords")
            } footer: {
                if let status { Text(status) }
            }

            if !vault.neverSave.isEmpty {
                Section("Never saved for") {
                    ForEach(vault.neverSave.sorted(), id: \.self) { origin in
                        HStack {
                            Text(URL(string: origin)?.host() ?? origin)
                            Spacer()
                            Button("Remove") { vault.setNeverSave(origin, false) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .confirmationDialog("Delete the password for \(pendingDelete?.host ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { vault.remove(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func row(_ login: SavedLogin) -> some View {
        HStack(spacing: 10) {
            FaviconView(url: nil, pageURL: URL(string: login.origin), title: login.host, size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.host).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if revealed.contains(login.id), let password = try? vault.password(for: login) {
                Text(password).font(.system(size: 12, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            } else {
                Text("••••••••").foregroundStyle(.secondary)
            }
            Button {
                if revealed.contains(login.id) { revealed.remove(login.id) } else { unlock { revealed.insert(login.id) } }
            } label: {
                Image(systemName: revealed.contains(login.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.contains(login.id) ? "Hide Password" : "Show Password")
            Button { copyPassword(login) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy Password")
            Menu {
                Button("Copy Username") { copy(login.username, label: "Username") }
                Button("Copy Password") { copyPassword(login) }
                if let url = URL(string: login.origin) { Button("Open \(login.host)") { NSWorkspace.shared.open(url) } }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = login }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .contextMenu {
            Button("Copy Username") { copy(login.username, label: "Username") }
            Button("Copy Password") { copyPassword(login) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = login }
        }
    }

    private func copyPassword(_ login: SavedLogin) {
        unlock {
            guard let password = try? vault.password(for: login) else { status = "Couldn't open that password."; return }
            copy(password, label: "Password")
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "\(label) copied."
    }

    /// Touch ID or the Mac's password, then five minutes without asking again.
    private func unlock(then action: @escaping @MainActor () -> Void) {
        if let unlockedUntil, unlockedUntil > .now { action(); return }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved passwords") { success, _ in
            Task { @MainActor in
                guard success else { return }
                unlockedUntil = .now.addingTimeInterval(5 * 60)
                action()
            }
        }
    }
}
