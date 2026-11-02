import SwiftUI

/// Called by the gate in ContentView. Shows the old setup until this flow is built, so a fresh
/// install does not get stuck on a stub.
struct OnboardingFlowView: View {
    let onFinish: () -> Void

    var body: some View {
        OnboardingView(onFinish: onFinish)
    }
}
