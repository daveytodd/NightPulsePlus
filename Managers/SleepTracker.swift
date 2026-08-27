import Foundation
import Combine

@MainActor final class SleepTracker: ObservableObject {
 @Published private(set) var isTracking = false
 @Published private(set) var startedAt: Date?
 func start() { isTracking = true; startedAt = Date() }
 func stop() -> SleepRecord? { guard let startedAt else { return nil }; isTracking = false; self.startedAt = nil; return SleepRecord(startTime: startedAt, endTime: Date()) }
}
