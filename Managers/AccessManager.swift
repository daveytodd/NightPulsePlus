import Foundation
import Combine
import Security

@MainActor
final class AccessManager: ObservableObject {
    enum SubscriptionStatus: String { case locked, unlocked }
    static let shared = AccessManager()
    @Published private(set) var isGrandfatheredVip: Bool
    @Published private(set) var subscriptionStatus: SubscriptionStatus
    private let defaults = UserDefaults.standard
    private let keychainKey = "com.nightpulse.grandfatheredVip"
    private let migrationCode = "RESTRIGHTVIP"

    private init() {
        isGrandfatheredVip = defaults.bool(forKey: "isGrandfatheredVip") || Self.readKeychain(keychainKey) == "true"
        subscriptionStatus = isGrandfatheredVip ? .unlocked : .locked
    }

    @discardableResult
    func redeem(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nightpulse",
              ["migrate", "redeem"].contains(url.host?.lowercased() ?? ""),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value?.uppercased() == migrationCode else { return false }
        isGrandfatheredVip = true
        subscriptionStatus = .unlocked
        defaults.set(true, forKey: "isGrandfatheredVip")
        defaults.set(SubscriptionStatus.unlocked.rawValue, forKey: "subscriptionStatus")
        Self.writeKeychain("true", key: keychainKey)
        return true
    }

    private static func writeKeychain(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
    }

    private static func readKeychain(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
