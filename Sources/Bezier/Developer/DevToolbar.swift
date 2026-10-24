import AppKit
import BezierCore
import SwiftUI

/// Arc's Developer Mode bar, docked to the top of the page card: "i" (toggle Developer Mode),
/// the full URL in monospace, then copy link · Portrait Mode · capture · console · network ·
/// inspect · close. Faint diagonal stripes mark it as a dev surface.
/// Reference: references/screenshots/web/arc-net/developers-2024-*.png
struct DevToolbar: View {
    let controller: BrowserWindowController
    let state: WindowState

    static let height: CGFloat = 32

    var body: some View {
        let url = controller.selectedTab?.url
        HStack(spacing: 2) {
            DevButton(symbol: "info.circle", help: "Turn Off Developer Mode for This Site (⌃D)") {
                controller.toggleDeveloperMode(nil)
            }
            Text(CommandBarModel.shortURL(url))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.leading, 4)
            Spacer(minLength: 12)
            DevButton(symbol: "link", help: "Copy URL (⇧⌘C)") { controller.copyURL(nil) }
            DevDivider()
            DevButton(symbol: "photo.artframe", help: "Capture in Portrait Mode") { state.portraitCaptureOpen = true }
                .popover(isPresented: Binding(get: { state.portraitCaptureOpen }, set: { state.portraitCaptureOpen = $0 }),
                         arrowEdge: .bottom) {
                    PortraitCaptureView(controller: controller)
                }
            DevButton(symbol: "camera", help: "Capture Page (⇧⌘2)") { controller.capturePage(nil) }
            DevDivider()
            DevButton(symbol: "terminal", help: "JavaScript Console (⌥⌘J)") { controller.showConsole(nil) }
            DevButton(symbol: "network", help: "Network & Resources") { controller.showNetwork(nil) }
            DevButton(symbol: "scope", help: "Inspect Elements (⌥⌘C)") { controller.inspectElement(nil) }
            DevDivider()
            DevButton(symbol: "xmark", help: "Close Tab (⌘W)") { controller.archiveTab(nil) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(DiagonalStripes(spacing: 7, opacity: 0.045).background(Color(nsColor: .textBackgroundColor)))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }
}

private struct DevButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary.opacity(hovering ? 0.85 : 0.6))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.84))
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct DevDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 5)
    }
}

/// 45° hairline stripes.
struct DiagonalStripes: View {
    var spacing: CGFloat = 8
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(.primary.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
