import Foundation
import Security

/// The account session, kept in the Keychain so it survives relaunches. On iOS: this device
/// only, after first unlock, so not a restore to another device. On the Mac: the login
/// keychain, which needs no signing team.
nonisolated enum Keychain {
    private static let service = "com.harrydatahub.GroundKit.auth"
    private static let account = "session"

    static func load() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ session: AuthSession?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var add = base
        add[kSecValueData as String] = data
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(add as CFDictionary, nil)
    }
}
