import AppKit
import BezierCore
import Observation
import SwiftUI

/// First-run walkthrough over the silk ribbons. Each step's text rises in word by word; leaving a
/// step blurs it away upward. The last step's button turns the whole thing into the browser (see
/// `OnboardingController.finish`).
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, spaces, sidebar, commandBar, arc, look, ready
    }

    var step: Step = .welcome
    var direction: CGFloat = 1
    var importState: ImportState = .idle
    var chosenLook: Look = .neutral
    @ObservationIgnored var hasArc = ArcImporter.isInstalled
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored var onImport: (() async -> ArcImportSummary?)?
    @ObservationIgnored var onChooseLook: ((Look) -> Void)?
    @ObservationIgnored var onMakeDefault: (() -> Void)?
    @ObservationIgnored var onStepChange: ((Step) -> Void)?
    /// Whether the background under the bottom bar is dark (it switches to light-on-dark).
    var barIsDark = false
    @ObservationIgnored var onBarFrame: ((CGRect) -> Void)?

    enum ImportState: Equatable { case idle, running, done(String), failed }
    enum Look: CaseIterable { case neutral, colour, dark }

    var steps: [Step] { Step.allCases.filter { $0 != .arc || hasArc } }

    func next() {
        guard let i = steps.firstIndex(of: step) else { return }
        if i + 1 < steps.count { go(to: steps[i + 1], direction: 1) } else { onFinish?() }
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        go(to: steps[i - 1], direction: -1)
    }

    private func go(to step: Step, direction: CGFloat) {
        self.direction = direction
        onStepChange?(step)
        withAnimation(.easeInOut(duration: 0.45)) { self.step = step }
    }
}

/// Onboarding palette: ink on white; blue, violet and bright purple (the ribbons' colours).
enum OnboardingInk {
    static let ink = Color(red: 0.10, green: 0.05, blue: 0.24)
    static let secondary = Color(red: 0.10, green: 0.05, blue: 0.24).opacity(0.62)
    static let blue = Color(red: 0x4D / 255, green: 0x6B / 255, blue: 1)
    static let violet = Color(red: 0x7B / 255, green: 0x2C / 255, blue: 1)
    static let purple = Color(red: 0xB2 / 255, green: 0x4D / 255, blue: 1)
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer().frame(height: 74)
                ZStack {
                    stepView(model.step)
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .modifier(active: BlurFade(amount: 1, rise: -24 * model.direction),
                                               identity: BlurFade(amount: 0, rise: 0))))
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 44)
                Spacer()
                footer
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.9 }
                    .padding(.bottom, 22)
            }
        }
        .coordinateSpace(name: "onboarding")
        .foregroundStyle(OnboardingInk.ink)
        .environment(\.colorScheme, .light)
        .background(KeyCatcher(onNext: model.next, onBack: model.back))
    }

    @ViewBuilder private func stepView(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome:
            VStack(spacing: 0) {
                BezierMark()
                    .padding(.top, 24)
                WordReveal(text: "A calmer home for the internet.", font: .system(size: 18), delay: 1.4, stagger: 0.03)
                    .foregroundStyle(OnboardingInk.secondary)
                    .padding(.top, -26)
            }
        case .spaces:
            StepText(title: "Keep the different sides of you apart.", message: "Work, side projects, life. Each Space has its own tabs and colour. Switch with ⌃1, ⌃2, ⌃3 — or swipe.")
        case .sidebar:
            StepText(title: "Pin what matters. Let the rest go.", message: "Today’s tabs tidy themselves into the Archive after 12 hours. Nothing is ever lost — ⇧⌘T brings it back.")
        case .commandBar:
            StepText(title: "⌘T does everything.", message: "Search, jump to any tab, run an action, or type “4pm utc” to see it in your time.")
        case .arc:
            VStack(spacing: 26) {
                StepText(title: "Bring your Arc with you.", message: "Arc stops working on December 22. Copy your Spaces, open tabs, Favorites, history and passwords in one go.")
                ArcImportButton(model: model)
                    .modifier(DelayedReveal(delay: 0.55))
            }
        case .look:
            VStack(spacing: 30) {
                StepText(title: "Pick a look.", message: "You can change it per Space anytime: hover a Space’s name and click the brush.")
                LookPicker(model: model)
                    .modifier(DelayedReveal(delay: 0.5))
            }
        case .ready:
            VStack(spacing: 30) {
                StepText(title: "Ready when you are.", message: "Your new browser is one click away.", titleSize: 56)
                HStack(spacing: 12) {
                    Button { model.onFinish?() } label: {
                        Text("Open Bezier").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 26).frame(height: 44)
                    }
                    .buttonStyle(OnboardingPrimaryButton())
                    Button("Make Default Browser") { model.onMakeDefault?() }
                        .buttonStyle(OnboardingSecondaryButton())
                }
                .modifier(DelayedReveal(delay: 0.5))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(model.steps, id: \.self) { s in
                    Capsule()
                        .fill(s == model.step ? (model.barIsDark ? Color.white : OnboardingInk.ink)
                                              : (model.barIsDark ? Color.white.opacity(0.35) : OnboardingInk.ink.opacity(0.18)))
                        .frame(width: s == model.step ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.step)
                }
            }
            Spacer()
            if model.step != .ready {
                Button("Skip") { model.onFinish?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.barIsDark ? Color.white.opacity(0.78) : OnboardingInk.secondary)
                Button { model.next() } label: {
                    HStack(spacing: 6) {
                        Text(model.step == .welcome ? "Get Started" : "Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                }
                .buttonStyle(OnboardingPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .frame(height: 56)
        .modifier(OnboardingGlassBar(dark: model.barIsDark))
        .animation(.easeInOut(duration: 0.35), value: model.barIsDark)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { model.onBarFrame?(geo.frame(in: .named("onboarding"))) }
                    .onChange(of: geo.frame(in: .named("onboarding"))) { _, frame in model.onBarFrame?(frame) }
            }
        }
    }
}

/// Liquid Glass container for the bottom controls (floating control layer, per Apple's
/// guidelines); a frosted fallback before macOS 26. Light or dark to match what's behind it.
private struct OnboardingGlassBar: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(dark ? .black.opacity(0.18) : .white.opacity(0.2)), in: shape)
                .environment(\.colorScheme, dark ? .dark : .light)
        } else {
            content.background(shape.fill(dark ? .black.opacity(0.35) : .white.opacity(0.6)))
        }
    }
}

// MARK: - Text that rises in word by word

private struct StepText: View {
    let title: String
    let message: String
    var titleSize: CGFloat = 46

    var body: some View {
        VStack(spacing: 16) {
            WordReveal(text: title, font: .system(size: titleSize, weight: .semibold, design: .default), tracking: -0.8,
                       delay: 0, wordSpacing: titleSize * 0.24)
            WordReveal(text: message, font: .system(size: 18, weight: .regular), tracking: 0, delay: 0.28, stagger: 0.018)
                .foregroundStyle(OnboardingInk.secondary)
                .frame(maxWidth: 520)
        }
        .multilineTextAlignment(.center)
    }
}

/// Words appear one after another: from blurred, lowered and transparent to sharp.
struct WordReveal: View {
    let text: String
    let font: Font
    var tracking: CGFloat = 0
    var delay: Double = 0
    var stagger: Double = 0.045
    var wordSpacing: CGFloat = 5

    @State private var shown = false

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        WrapLayout(spacing: wordSpacing, lineSpacing: 2) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(font)
                    .tracking(tracking)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .scaleEffect(shown ? 1 : 0.97, anchor: .bottom)
                    .animation(.spring(response: 0.75, dampingFraction: 0.86).delay(delay + Double(index) * stagger), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

/// Centered, wrapping row layout (words flow onto new lines like text).
struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.midX - line.width / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height)), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !lines[lines.count - 1].indices.isEmpty && lines[lines.count - 1].width + size.width > width {
                lines.append(Line())
            }
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += size.width + (lines[lines.count - 1].indices.count > 1 ? spacing : 0)
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}

/// Exit transition: blur out while drifting up (or down when going back).
private struct BlurFade: ViewModifier {
    let amount: CGFloat
    let rise: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: 5 * amount).opacity(1 - amount).offset(y: rise * amount).scaleEffect(1 - 0.03 * amount)
    }
}

private struct DelayedReveal: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(delay), value: shown)
            .onAppear { shown = true }
    }
}

// MARK: - Controls

private struct ArcImportButton: View {
    let model: OnboardingModel

    var body: some View {
        switch model.importState {
        case .idle:
            Button {
                model.importState = .running
                Task {
                    let summary = await model.onImport?()
                    model.importState = summary.map { .done(Self.describe($0)) } ?? .failed
                }
            } label: {
                Label("Import from Arc", systemImage: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 22).frame(height: 42)
            }
            .buttonStyle(OnboardingPrimaryButton())
        case .running:
            ProgressView().controlSize(.regular).tint(OnboardingInk.violet)
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OnboardingInk.ink)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        case .failed:
            Text("Couldn’t read Arc’s data. You can try again later in Settings › Import.")
                .font(.system(size: 13)).foregroundStyle(OnboardingInk.secondary)
        }
    }

    static func describe(_ s: ArcImportSummary) -> String {
        let tabs = s.pinnedTabs + s.todayTabs
        var parts = ["\(tabs) tab\(tabs == 1 ? "" : "s")"]
        if s.spacesAdded > 0 { parts.insert("\(s.spacesAdded) Space\(s.spacesAdded == 1 ? "" : "s")", at: 0) }
        if s.favorites > 0 { parts.append("\(s.favorites) Favorites") }
        if s.historyEntries > 0 { parts.append("\(s.historyEntries.formatted()) history pages") }
        if s.passwords > 0 { parts.append("\(s.passwords) password\(s.passwords == 1 ? "" : "s")") }
        return "Imported " + parts.joined(separator: " · ")
    }
}

private struct LookPicker: View {
    let model: OnboardingModel

    var body: some View {
        HStack(spacing: 14) {
            card(.neutral, title: "Neutral", subtitle: "Follows light & dark", colors: [Color(white: 0.95), Color(white: 0.16)])
            card(.colour, title: "Colour", subtitle: "A tint per Space", colors: [Color(red: 0.85, green: 0.82, blue: 0.97), Color(red: 0.95, green: 0.79, blue: 0.87)])
            card(.dark, title: "Dark", subtitle: "Always dark", colors: [Color(white: 0.2), Color(white: 0.12)])
        }
    }

    private func card(_ look: OnboardingModel.Look, title: String, subtitle: String, colors: [Color]) -> some View {
        let selected = model.chosenLook == look
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.chosenLook = look }
            model.onChooseLook?(look)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                Capsule().fill(.white.opacity(0.6)).frame(width: CGFloat(44 - i * 8), height: 5)
                            }
                        }
                        .padding(10)
                    }
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(OnboardingInk.ink)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(OnboardingInk.secondary)
            }
            .padding(12)
            .frame(width: 168)
            // Selected: solid card and a check; no outline.
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(selected ? 1 : 0.6)))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, OnboardingInk.ink)
                        .padding(18)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .scaleEffect(selected ? 1.03 : 1)
        }
        .buttonStyle(PressableStyle(scale: 0.96))
    }
}

private struct OnboardingPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Capsule().fill(OnboardingInk.violet))
            .shadow(color: OnboardingInk.violet.opacity(0.45), radius: 16, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct OnboardingSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 38)
            .modifier(OnboardingGlass())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Liquid Glass capsule on macOS 26 (floating control over the shader), frosted elsewhere.
private struct OnboardingGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(.horizontal, 4).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.padding(.horizontal, 4).background(Capsule().fill(.white.opacity(0.14)))
        }
    }
}

/// → / Return continue, ← goes back.
private struct KeyCatcher: NSViewRepresentable {
    let onNext: () -> Void
    let onBack: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onNext = onNext
        view.onBack = onBack
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onNext = onNext
        view.onBack = onBack
    }

    final class CatcherView: NSView {
        var onNext: (() -> Void)?
        var onBack: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 124, 49: onNext?()        // → , space
            case 123: onBack?()            // ←
            default: super.keyDown(with: event)
            }
        }
    }
}
