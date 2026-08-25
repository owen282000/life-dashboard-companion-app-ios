import Foundation

enum HealthSyncResult {
    case noData
    case success(syncCounts: [HealthDataType: Int])
    case failure(error: String)
}