import Foundation
import Network

/// @unchecked Sendable: `wasDisconnected` is only touched on the monitor's own
/// serial queue, and `isConnected` is only mutated on the main queue.
final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.networkmonitor")

    @Published var isConnected = true

    private var wasDisconnected = false

    private init() {
        configureHandler()
        monitor.start(queue: queue)
    }

    private func configureHandler() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied

            DispatchQueue.main.async {
                self.isConnected = connected
            }

            // Drain pending queue when network comes back
            if connected && self.wasDisconnected {
                self.wasDisconnected = false
                Task {
                    await HealthSyncManager.shared.drainPendingQueue()
                }
            }

            if !connected {
                self.wasDisconnected = true
            }
        }
    }
}
