import Foundation
import Security

struct APIConnectionConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let token: String

    var webSocketURL: URL? {
        URL(string: "ws://\(host):\(port)/ws")
    }

    var httpBaseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}

enum AppConfig {
    static let defaultPort = 8095

    private static let hostDefaultsKey = "musicassistant.api.host"
    private static let portDefaultsKey = "musicassistant.api.port"

    static func loadHost() -> String {
        (UserDefaults.standard.string(forKey: hostDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loadPort() -> Int {
        let value = UserDefaults.standard.integer(forKey: portDefaultsKey)
        return value > 0 ? value : defaultPort
    }

    static func saveHost(_ host: String) {
        UserDefaults.standard.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: hostDefaultsKey)
    }

    static func savePort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: portDefaultsKey)
    }

    static func loadToken() -> String {
        KeychainTokenStore.loadToken() ?? ""
    }

    static func saveToken(_ token: String) -> Bool {
        KeychainTokenStore.saveToken(token)
    }
}

private enum KeychainTokenStore {
    private static let account = "musicassistant-api-token"
    private static let service = "MusicAssistantMenuBar"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return token
    }

    static func saveToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }
}
