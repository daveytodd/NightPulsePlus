import Combine
import Foundation
import HealthKit

@MainActor final class HealthKitManager: ObservableObject {
 @Published private(set) var isAuthorized = false
 private let store = HKHealthStore()
 func requestAuthorization() async throws { guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }; try await store.requestAuthorization(toShare: [], read: [type]); isAuthorized = true }
}
