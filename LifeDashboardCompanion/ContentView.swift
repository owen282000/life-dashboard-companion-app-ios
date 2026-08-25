import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

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
    }
}
