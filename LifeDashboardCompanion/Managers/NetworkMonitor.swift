import Foundation
import Network

class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.networkmonitor")

    @Published var isConnected = true

    private var wasDisconnected = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied

            DispatchQueue.main.async {
                self?.isConnected = connected
            }

            // Drain pending queue when network comes back
            if connected && self?.wasDisconnected == true {
                self?.wasDisconnected = false
                Task {
                    await HealthSyncManager.shared.drainPendingQueue()
                }
            }

            if !connected {
                self?.wasDisconnected = true
            }
        }
        monitor.start(queue: queue)
    }
}
