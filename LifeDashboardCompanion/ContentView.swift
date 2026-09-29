import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @StateObject private var pairing = PairingCoordinator()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HealthKitScreen()
                    .navigationTitle("Health")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Health", systemImage: "heart.fill")
            }
            .tag(0)

            NavigationStack {
                LogsScreen()
                    .navigationTitle("Logs")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Logs", systemImage: "doc.text.fill")
            }
            .tag(1)

            NavigationStack {
                AboutScreen()
                    .navigationTitle("About")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("About", systemImage: "info.circle.fill")
            }
            .tag(2)
        }
        .tint(.accentColor)
        .environmentObject(pairing)
        // A lifedashboard:// link from the landing page, on a warm or a cold start.
        .onOpenURL { pairing.open($0) }
        .onChange(of: pairing.pending?.id) { _, id in
            if id != nil { selectedTab = 0 }
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
