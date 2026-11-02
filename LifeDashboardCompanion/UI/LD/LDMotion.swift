import SwiftUI

// MARK: - Tab direction

/// Which way the tab content enters: forward when the new tab sits after the old one.
/// `none` outside a switch, so returning from a pushed screen does not slide.
enum LDTabDirection: Sendable {
    case none, forward, backward

    /// Where the content starts, in points: it comes from the side of the tab it goes towards.
    var startOffset: CGFloat {
        switch self {
        case .none: return 0
        case .forward: return 18
        case .backward: return -18
        }
    }
}

extension EnvironmentValues {
    /// The direction of the tab switch in progress, set by ContentView.
    @Entry var ldTabDirection: LDTabDirection = .none
}

// MARK: - Curves

enum LDMotion {
    /// cubic-bezier(.2,.8,.2,1) from the boards.
    static func enter(duration: Double = 0.22) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
}

// MARK: - Modifiers

private struct LDTabEnter: ViewModifier {
    @Environment(\.ldTabDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    func body(content: Content) -> some View {
        let settled = entered || direction == .none || reduceMotion
        content
            .offset(x: settled ? 0 : direction.startOffset)
            .opacity(settled ? 1 : 0)
            .onAppear {
                withAnimation(LDMotion.enter()) { entered = true }
            }
            .onDisappear { entered = false }
    }
}

private struct LDStaggerRise: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    func body(content: Content) -> some View {
        let settled = risen || reduceMotion
        content
            .offset(y: settled ? 0 : 10)
            .opacity(settled ? 1 : 0)
            .onAppear {
                // Capped so the last row of a long list does not arrive after the user has moved on.
                withAnimation(LDMotion.enter(duration: 0.32).delay(Double(min(index, 8)) * 0.04)) {
                    risen = true
                }
            }
            .onDisappear { risen = false }
    }
}

extension View {
    /// Slides the view in from the side of the tab switch. ContentView already sets this on the
    /// root screen of each tab, so a screen only needs it for content it swaps itself.
    func ldTabEnter() -> some View {
        modifier(LDTabEnter())
    }

    /// Rises and fades the view in when it appears. `index` is its place in the stagger.
    func ldStaggerRise(_ index: Int = 0) -> some View {
        modifier(LDStaggerRise(index: index))
    }
}
