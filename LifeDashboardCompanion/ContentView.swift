import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var healthShowsAbout = false
    @State private var logsShowsAbout = false
    @StateObject private var pairing = PairingCoordinator()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HealthKitScreen()
                    .navigationTitle("Health")
                    .navigationBarTitleDisplayMode(.inline)
                    .aboutButton(isPresented: $healthShowsAbout)
            }
            .tabItem {
                Label("Health", systemImage: "heart.fill")
            }
            .tag(0)

            NavigationStack {
                LogsScreen()
                    .navigationTitle("Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .aboutButton(isPresented: $logsShowsAbout)
            }
            .tabItem {
                Label("Logs", systemImage: "clock.arrow.circlepath")
            }
            .tag(1)
        }
        // Each tab in its own accent, as in the Android app: green for Health, blue for Logs.
        .tint(selectedTab == 1 ? Brand.logsInk : Color.accentColor)
        .environmentObject(pairing)
        .onAppear {
            #if DEBUG
            // For screenshots of every page: -ld.tab 1 opens Logs, -ld.about YES opens About.
            let arguments = UserDefaults.standard
            selectedTab = arguments.integer(forKey: "ld.tab")
            if arguments.bool(forKey: "ld.about") {
                if selectedTab == 1 { logsShowsAbout = true } else { healthShowsAbout = true }
            }
            #endif
        }
        // A lifedashboard:// link from the landing page, on a warm or a cold start.
        .onOpenURL { pairing.open($0) }
        .onChange(of: pairing.pending?.id) { _, id in
            if id != nil { selectedTab = 0 }
        }
        // A pairing link lands on the Health screen itself, not on About pushed over it.
        .onChange(of: pairing.incoming) { _, _ in
            healthShowsAbout = false
            logsShowsAbout = false
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
    }
}

private extension View {
    /// The (i) in the navigation bar that opens About, like the action in the Android app's top bar.
    func aboutButton(isPresented: Binding<Bool>) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresented.wrappedValue = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About")
            }
        }
        .navigationDestination(isPresented: isPresented) {
            AboutScreen()
                .navigationTitle("About")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
