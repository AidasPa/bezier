import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// Keeps the engine's per-site styles and scripts in step with the saved Boosts.
@MainActor
final class BoostsController {
    let store: BoostStore
    private let engine: any WebEngine

    init(engine: any WebEngine, store: BoostStore = BoostStore()) {
        self.engine = engine
        self.store = store
        store.onChange = { [weak self] in self?.apply() }
        apply()
    }

    private func apply() {
        engine.siteCustomizations = store.boosts.filter { $0.isEnabled && !$0.isEmpty }
            .map { SiteCustomization(domain: $0.domain, css: $0.stylesheet, js: $0.js) }
    }
}

/// One open Boost editor. Every change saves (and restyles the page) straight away.
@MainActor
@Observable
final class BoostEditorModel {
    var boost: Boost {
        didSet { if boost != oldValue { store.save(boost) } }
    }
    var zapping = false
    var codeTab = 0
    @ObservationIgnored private let store: BoostStore
    @ObservationIgnored var onZap: ((Bool) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onReload: (() -> Void)?

    init(boost: Boost, store: BoostStore) {
        self.boost = boost
        self.store = store
    }

    func delete() {
        store.remove(boost.id)
        onClose?()
    }
}

/// Shows the Boost editor for the selected tab's site in a popover over the page. It stays
/// open while you click around the page (for Zap); close it with its × or Escape.
@MainActor
final class BoostEditorPresenter: NSObject, NSPopoverDelegate {
    private unowned let browser: BrowserWindowController
    private var popover: NSPopover?
    private weak var zapContent: (any WebContent)?

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isShowing: Bool { popover?.isShown == true }

    func show() {
        guard let content = browser.selectedContent, let domain = Boost.domain(for: content.state.url ?? browser.selectedTab?.url) else {
            browser.showToast("Boosts work on websites", symbol: "paintbrush.pointed")
            return
        }
        close()
        let store = browser.app.boosts.store
        let model = BoostEditorModel(boost: store.boost(for: content.state.url) ?? Boost(domain: domain), store: store)
        model.onClose = { [weak self] in self?.close() }
        model.onReload = { content.reload(ignoringCache: false) }
        model.onZap = { [weak self, weak model] on in
            guard let self, let model else { return }
            if on {
                self.zapContent = content
                content.beginZap { [weak model] selector in
                    guard let model else { return }
                    if let selector { model.boost.zapped.append(selector) } else { model.zapping = false }
                }
                self.browser.window?.makeFirstResponder(content.view)
            } else {
                content.endZap()
            }
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: BoostEditorView(model: model))
        let view = browser.root.card
        let y = view.isFlipped ? 0 : view.bounds.maxY - 1
        popover.show(relativeTo: NSRect(x: view.bounds.maxX - 60, y: y, width: 1, height: 1), of: view,
                     preferredEdge: view.isFlipped ? .minY : .maxY)
        self.popover = popover
    }

    func close() {
        zapContent?.endZap()
        zapContent = nil
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        zapContent?.endZap()
        zapContent = nil
    }
}

struct BoostEditorView: View {
    @Bindable var model: BoostEditorModel

    private static let fonts = ["Georgia", "New York", "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Palatino",
                                "Baskerville", "SF Mono", "Menlo", "Comic Sans MS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            colours
            fontPicker
            zap
            code
            HStack {
                Button("Delete Boost", role: .destructive) { model.delete() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                Spacer()
                Text("Changes apply as you make them.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onExitCommand { model.onClose?() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Boost").font(.system(size: 13, weight: .semibold))
                Text(model.boost.domain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("On", isOn: $model.boost.isEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(model.boost.isEnabled ? "Turn Boost Off" : "Turn Boost On")
            Button { model.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.85))
            .help("Close (Esc)")
        }
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Colours").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Dark", isOn: $model.boost.invert).toggleStyle(.checkbox).controlSize(.small)
                if model.boost.hue != 0 || model.boost.saturation != 1 || model.boost.brightness != 1 {
                    Button("Reset") { model.boost.hue = 0; model.boost.saturation = 1; model.boost.brightness = 1 }
                        .buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
            slider("Hue", value: $model.boost.hue, in: -180...180, rainbow: true)
            slider("Saturation", value: $model.boost.saturation, in: 0...2)
            slider("Brightness", value: $model.boost.brightness, in: 0.5...1.5)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, rainbow: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .background {
                    if rainbow {
                        Capsule().fill(LinearGradient(colors: [.cyan, .blue, .purple, .red, .orange, .yellow, .green, .cyan],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(height: 4).opacity(0.7)
                    }
                }
        }
    }

    private var fontPicker: some View {
        HStack {
            Text("Font").font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker("Font", selection: Binding(get: { model.boost.font ?? "" }, set: { model.boost.font = $0.isEmpty ? nil : $0 })) {
                Text("Page default").tag("")
                Divider()
                ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var zap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Zap").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(model.zapping ? "Done Zapping" : "Zap Elements…") {
                    model.zapping.toggle()
                    model.onZap?(model.zapping)
                }
                .controlSize(.small)
            }
            if model.zapping {
                Text("Click anything on the page to hide it. Escape stops.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !model.boost.zapped.isEmpty {
                HStack {
                    Text(model.boost.zapped.count == 1 ? "1 element hidden" : "\(model.boost.zapped.count) elements hidden")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo Last") { model.boost.zapped.removeLast() }.buttonStyle(.borderless).font(.system(size: 11.5))
                    Button("Restore All") { model.boost.zapped.removeAll() }.buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Code").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Language", selection: $model.codeTab) {
                    Text("CSS").tag(0)
                    Text("JS").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            TextEditor(text: model.codeTab == 0 ? $model.boost.css : $model.boost.js)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            if model.codeTab == 1 {
                HStack {
                    Text("JavaScript runs when the page loads.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload Page") { model.onReload?() }.buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
        }
    }
}
