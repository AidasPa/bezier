import AppKit
import SwiftUI

/// Find on page state for one window.
@MainActor
@Observable
final class FindModel {
    var isVisible = false
    var query = ""
    /// 1-based index of the selected match; 0 when nothing is selected.
    var current = 0
    var total = 0
    var hasSearched = false
    /// Bumped to put the cursor back in the field (⌘F while the bar is already open).
    var focusRequest = 0
    @ObservationIgnored var onSearch: ((_ backwards: Bool, _ restart: Bool) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    var notFound: Bool { hasSearched && !query.isEmpty && total == 0 }
}

/// ⌘F: a floating field at the top-right of the page. It searches as you type; Return and ⌘G
/// go to the next match, ⇧Return and ⇧⌘G to the previous one, Escape closes.
struct FindBar: View {
    @Bindable var model: FindModel
    @FocusState private var focused: Bool
    @State private var pending: Task<Void, Never>?

    static let size = CGSize(width: 330, height: 38)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            TextField("Find on page", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { model.onSearch?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true, false) }
                .onExitCommand { model.onClose?() }
            Text(count)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(model.notFound ? Color.red.opacity(0.85) : .secondary)
                .fixedSize()
                .padding(.horizontal, 4)
            button("chevron.up", help: "Previous Match (⇧⌘G)") { model.onSearch?(true, false) }
            button("chevron.down", help: "Next Match (⌘G)") { model.onSearch?(false, false) }
            button("xmark", help: "Done (Esc)") { model.onClose?() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(GlassPanel(cornerRadius: Self.size.height / 2))
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
        .onChange(of: model.query) {
            // Search as you type, a beat after the last keystroke.
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                model.onSearch?(false, true)
            }
        }
    }

    private var count: String {
        guard !model.query.isEmpty, model.hasSearched else { return "" }
        return model.total == 0 ? "No matches" : "\(model.current) of \(model.total)"
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .help(help)
        .disabled(symbol != "xmark" && model.total == 0)
    }
}
