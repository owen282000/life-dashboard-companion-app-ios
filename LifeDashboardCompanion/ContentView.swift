import SwiftUI

struct ContentView: View {
    @StateObject private var navigator = LDNavigator()
    @StateObject private var pairing = PairingCoordinator()
    // UI state, not a setting, so it stays out of PreferencesManager and the settings backup.
    @AppStorage("onboarding_completed") private var onboardingCompleted = false
    // Set when the setup first shows: it picks the essentials on its own, so a setup that was
    // left halfway no longer looks like a fresh install, and would otherwise not come back.
    @AppStorage("onboarding_started") private var onboardingStarted = false
    @State private var showOnboarding = false

    init() {
        LDNavigationAppearance.apply()
    }

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingFlowView {
                    onboardingCompleted = true
                    showOnboarding = false
                }
            } else {
                tabs
            }
        }
        .onAppear {
            guard !onboardingCompleted else { return }
            let prefs = PreferencesManager.shared
            if onboardingStarted || OnboardingView.isFreshInstall(
                webhookUrls: prefs.healthWebhookUrls,
                mqttHost: prefs.mqttHost,
                enabledTypes: prefs.healthEnabledDataTypes
            ) {
                onboardingStarted = true
                showOnboarding = true
            } else {
                // An upgrade from a version without the setup: it is already set up.
                onboardingCompleted = true
            }
        }
        // A lifedashboard:// link from the landing page, on a warm or a cold start.
        .onOpenURL { pairing.open($0) }
        .onChange(of: pairing.pending?.id) { _, id in
            if id != nil { navigator.selectedTab = LDNavigator.healthTab }
        }
        // A pairing link lands on the Health screen itself, not on a page pushed over it.
        .onChange(of: pairing.incoming) { _, _ in
            navigator.clearForPairing()
        }
        .fullScreenCover(isPresented: $pairing.scanning, onDismiss: pairing.scannerDismissed) {
            PairingScannerView(
                onScanned: { pairing.scanned($0) },
                onClose: { pairing.scanning = false }
            )
        }
        .sheet(item: $pairing.pending) { pending in
            PairingSheet(link: pending.link)
        }
        .alert(
            "Cannot pair",
            isPresented: Binding(
                get: { pairing.problem != nil },
                set: { if !$0 { pairing.problem = nil } }
            ),
            presenting: pairing.problem
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
        // Outside the presentations above, so the cover and the sheets get them too.
        .tint(LDTheme.accentText)
        .environmentObject(pairing)
        .environmentObject(navigator)
    }

    private var tabs: some View {
        TabView(selection: $navigator.selectedTab) {
            NavigationStack(path: $navigator.healthPath) {
                HomeScreen()
                    .ldTabRoot(title: "Health")
            }
            .tabItem {
                Label("Health", systemImage: "heart.fill")
            }
            .tag(LDNavigator.healthTab)

            NavigationStack(path: $navigator.logsPath) {
                LogsListScreen()
                    .ldTabRoot(title: "Logs")
            }
            .tabItem {
                Label("Logs", systemImage: "clock.arrow.circlepath")
            }
            .tag(LDNavigator.logsTab)
        }
        .environment(\.ldTabDirection, navigator.tabDirection)
        .sheet(item: $navigator.sheet, onDismiss: navigator.sheetDismissed) { route in
            NavigationStack {
                route.screen
            }
            .tint(LDTheme.accentText)
            .presentationDragIndicator(.visible)
            .presentationBackground(LDTheme.sheet)
        }
        .onAppear {
            #if DEBUG
            navigator.applyDebugArguments()
            #endif
        }
    }
}

/// Whether About is pushed on each tab. Each tab has its own navigation stack, so About stayed open on
/// a tab after switching away and back; leaving a tab now closes it there.
struct AboutPresentation: Equatable {
    var health = false
    var logs = false

    mutating func leave(tab: Int) {
        if tab == 1 { logs = false } else { health = false }
    }
}

private extension View {
    /// The root screen of a tab: no bar of its own, as on the boards, with the one route table of
    /// the app. The title stays for VoiceOver, and the slide comes with the switch of tabs.
    func ldTabRoot(title: LocalizedStringKey) -> some View {
        ldTabEnter()
            .navigationTitle(title)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarRole(.editor)
            .navigationDestination(for: LDRoute.self) { route in
                // The editor role leaves only the chevron on the back button.
                route.destination.toolbarRole(.editor)
            }
    }
}

/// Space Grotesk titles on the dark ground. UIKit's appearance is the only way to set the font of
/// a SwiftUI navigation bar.
private enum LDNavigationAppearance {
    @MainActor private static var applied = false

    @MainActor static func apply() {
        guard !applied else { return }
        applied = true

        let text = LDTone.text.uiColor
        let title = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: LDFontName.bold, size: 17) ?? .systemFont(ofSize: 17, weight: .bold)
        )
        let bold = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: LDFontName.bold, size: 16) ?? .systemFont(ofSize: 16, weight: .bold)
        )
        let regular = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: LDFontName.regular, size: 16) ?? .systemFont(ofSize: 16)
        )

        func styled(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            appearance.titleTextAttributes = [.font: title, .foregroundColor: text]
            appearance.largeTitleTextAttributes = [.foregroundColor: text]
            appearance.buttonAppearance.normal.titleTextAttributes = [.font: regular]
            appearance.doneButtonAppearance.normal.titleTextAttributes = [.font: bold]
            return appearance
        }

        // Nothing behind the bar at the top of a page. Scrolled, iOS 26 draws its own edge effect;
        // earlier versions get the ground, or the content would run through the title.
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        let scrolled = UINavigationBarAppearance()
        if #available(iOS 26, *) {
            scrolled.configureWithTransparentBackground()
        } else {
            scrolled.configureWithOpaqueBackground()
            scrolled.backgroundColor = LDTone.ground.uiColor
            scrolled.shadowColor = LDTone.hairline.uiColor
        }

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = styled(scrolled)
        bar.compactAppearance = styled(scrolled)
        bar.scrollEdgeAppearance = styled(edge)
        bar.compactScrollEdgeAppearance = styled(edge)
    }
}
