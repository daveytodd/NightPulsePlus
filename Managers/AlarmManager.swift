import Foundation
import Combine
import UserNotifications

@MainActor final class AlarmManager: ObservableObject {
 @Published private(set) var authorizationGranted = false
 func requestAuthorization() async { authorizationGranted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }
 func cancel(identifier: String) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier]) }
}
