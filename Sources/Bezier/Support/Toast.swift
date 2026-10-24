import AppKit
import Observation
import SwiftUI

/// Brief confirmation pill ("Copied URL"), shown over the bottom of the content card.
/// A floating control, so it gets Liquid Glass.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    var current: Toast?

    func show(_ text: String, symbol: String) {
        let toast = Toast(text: text, symbol: symbol)
        withAnimation(Motion.spring) { current = toast }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if current == toast { withAnimation(.easeOut(duration: 0.25)) { current = nil } }
        }
    }
}

struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold))
                    Text(toast.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .modifier(GlassCapsule())
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(VisualEffectBackground(material: .hudWindow))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// Hosting view that never takes clicks (overlays like toasts).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
