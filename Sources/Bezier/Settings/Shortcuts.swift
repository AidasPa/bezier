import AppKit
import Observation
import SwiftUI

/// Custom keyboard shortcuts: any menu command can get a different shortcut (or none). Saved
/// in user defaults by the command's action and tag, and laid over the menu at launch.
@MainActor
@Observable
final class ShortcutStore {
    struct Shortcut: Codable, Equatable {
        /// The menu key equivalent; empty means no shortcut.
        var key: String
        var modifiers: UInt

        init(key: String, modifiers: NSEvent.ModifierFlags) {
            self.key = key
            self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
        }

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
        static let cleared = Shortcut(key: "", modifiers: [])
    }

    private(set) var overrides: [String: Shortcut] = [:]
    @ObservationIgnored private var originals: [String: Shortcut] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let key = "CustomShortcuts"

    init() {
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            overrides = saved
        }
    }

    static func id(for item: NSMenuItem) -> String? {
        item.action.map { NSStringFromSelector($0) + "#\(item.tag)" }
    }

    /// Remembers each item's built-in shortcut, then applies the custom ones.
    func apply(to menu: NSMenu) {
        for item in Self.items(in: menu) {
            guard let id = Self.id(for: item), !item.isHidden else { continue }
            if originals[id] == nil { originals[id] = Shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask) }
            let shortcut = overrides[id] ?? originals[id]!
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.flags
        }
    }

    /// `nil` puts back the built-in shortcut. Another command already using the shortcut loses it.
    func set(_ shortcut: Shortcut?, for id: String, in menu: NSMenu) {
        if let shortcut, !shortcut.key.isEmpty, let clash = self.id(using: shortcut, in: menu), clash != id {
            overrides[clash] = .cleared
        }
        overrides[id] = shortcut == originals[id] ? nil : shortcut
        if shortcut == nil { overrides[id] = nil }
        save()
        apply(to: menu)
    }

    func resetAll(in menu: NSMenu) {
        overrides = [:]
        save()
        apply(to: menu)
    }

    func isCustom(_ id: String) -> Bool { overrides[id] != nil }

    /// The command currently using a shortcut.
    func id(using shortcut: Shortcut, in menu: NSMenu) -> String? {
        Self.items(in: menu).first { item in
            !item.isHidden && item.keyEquivalent.lowercased() == shortcut.key.lowercased()
                && item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == shortcut.flags
        }.flatMap(Self.id(for:))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: Self.key) }
    }

    static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items(in:)) ?? []) }
    }

    static func describe(key: String, modifiers m: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let symbols: [String: String] = [
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→",
            String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓",
            "\r": "↩", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫",
        ]
        return s + (symbols[key] ?? key.uppercased())
    }
}

/// Settings › Shortcuts: every menu command with its shortcut. Click a shortcut, then press the
/// new keys (with ⌘, ⌃ or ⌥); Escape cancels, Delete removes it.
struct ShortcutsPane: View {
    let store: ShortcutStore

    @State private var recording: String?
    @State private var monitor: Any?
    @State private var search = ""
    @State private var note: String?

    private struct Row: Identifiable {
        let id: String
        let title: String
        let keys: String
    }

    private var groups: [(String, [Row])] {
        _ = store.overrides                                   // refresh when shortcuts change
        guard let bar = NSApp.mainMenu else { return [] }
        return bar.items.compactMap { top in
            guard let menu = top.submenu else { return nil }
            var seen = Set<String>()
            let rows = ShortcutStore.items(in: menu).compactMap { item -> Row? in
                guard let id = ShortcutStore.id(for: item), !item.isHidden, !item.isSeparatorItem, item.submenu == nil,
                      !item.title.isEmpty, seen.insert(id).inserted else { return nil }
                guard search.isEmpty || item.title.localizedCaseInsensitiveContains(search) else { return nil }
                return Row(id: id, title: item.title, keys: ShortcutStore.describe(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))
            }
            return rows.isEmpty ? nil : (top.title, rows)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search", text: $search, prompt: Text("Search commands"))
            } footer: {
                HStack {
                    Text(note ?? "Click a shortcut to change it.")
                    Spacer()
                    if !store.overrides.isEmpty, let menu = NSApp.mainMenu {
                        Button("Reset All") { store.resetAll(in: menu) }.buttonStyle(.borderless)
                    }
                }
            }
            ForEach(groups, id: \.0) { title, rows in
                Section(title) {
                    ForEach(rows) { row in
                        LabeledContent(row.title) {
                            HStack(spacing: 6) {
                                if store.isCustom(row.id), recording != row.id, let menu = NSApp.mainMenu {
                                    Button { store.set(nil, for: row.id, in: menu) } label: { Image(systemName: "arrow.uturn.backward") }
                                        .buttonStyle(.borderless).help("Use the Original Shortcut")
                                }
                                Button { record(row.id) } label: {
                                    Text(recording == row.id ? "Type shortcut…" : (row.keys.isEmpty ? "Add" : row.keys))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(recording == row.id ? Color.accentColor : (row.keys.isEmpty ? .secondary : .primary))
                                        .frame(minWidth: 70)
                                        .padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.primary.opacity(recording == row.id ? 0.1 : 0.05)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onDisappear(perform: stopRecording)
    }

    private func record(_ id: String) {
        stopRecording()
        recording = id
        note = "Press the new shortcut. Escape cancels, Delete removes it."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers ?? ""
            MainActor.assumeIsolated { handle(keyCode: keyCode, flags: flags, characters: characters, for: id) }
            return nil
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String, for id: String) {
        guard let menu = NSApp.mainMenu else { return }
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case 53:                                                  // Escape
            note = nil
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty:   // Delete: no shortcut
            store.set(.cleared, for: id, in: menu)
            note = "Shortcut removed."
        default:
            guard !modifiers.isDisjoint(with: [.command, .control, .option]) || (flags.contains(.function) && keyCode >= 96) else {
                note = "Shortcuts need ⌘, ⌃ or ⌥."
                return
            }
            let shortcut = ShortcutStore.Shortcut(key: characters.lowercased(), modifiers: modifiers)
            let clash = store.id(using: shortcut, in: menu)
            store.set(shortcut, for: id, in: menu)
            note = clash != nil && clash != id ? "That shortcut was taken; the other command no longer has one." : nil
        }
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
