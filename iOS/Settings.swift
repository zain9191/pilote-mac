import Foundation
import Security

/// Réglages de connexion : l'adresse dans les préférences, le jeton dans le trousseau.
enum Settings {
    private static let addressKey = "address"

    static var address: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: addressKey) }
    }

    static var url: URL? {
        Address.url(from: address)
    }

    static var token: String? {
        get { Keychain.read() }
        set { Keychain.write(newValue) }
    }

    static var isComplete: Bool {
        url != nil && !(token ?? "").isEmpty
    }
}

/// Jeton dans le trousseau, accessible après le premier déverrouillage, jamais
/// synchronisé ni restauré sur un autre appareil.
enum Keychain {
    private static let service = "com.zain9191.pilote.token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
