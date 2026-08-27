import Combine
import Foundation
import WatchConnectivity

@MainActor final class WatchManager: NSObject, ObservableObject, WCSessionDelegate {
 @Published private(set) var isReachable = false
 override init() { super.init(); if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() } }
 nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) { Task { @MainActor in isReachable = session.isReachable } }
 nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in isReachable = session.isReachable } }
}
