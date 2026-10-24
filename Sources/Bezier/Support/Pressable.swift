import SwiftUI

/// Subtle spring "squish" on press for buttons (Arc's tactile feel).
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.9)
                                               : .spring(response: 0.32, dampingFraction: 0.52), value: configuration.isPressed)
    }
}

/// The same squish for rows driven by tap gestures (tabs, folders, tiles). Runs alongside
/// the row's own gestures, so taps and context menus are unaffected.
struct PressScale: ViewModifier {
    var scale: CGFloat = 0.97
    @GestureState private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(pressed ? .spring(response: 0.18, dampingFraction: 0.9)
                               : .spring(response: 0.34, dampingFraction: 0.5), value: pressed)
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
    }
}

extension View {
    func pressScale(_ scale: CGFloat = 0.97) -> some View { modifier(PressScale(scale: scale)) }
}
