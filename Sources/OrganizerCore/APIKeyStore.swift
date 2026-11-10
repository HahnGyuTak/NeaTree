import Foundation
import Security

/// Keys are kept in the current user's Keychain, never in configuration JSON.
public enum APIKeyStore {
    private static let service = "local.file-organizer.openai"
    private static let account = "api-key"
    public static func read() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError(errSecParam) }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        let data = Data(trimmed.utf8)
        let updated = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status) }
        } else if updated != errSecSuccess { throw KeychainError(updated) }
    }
    public static func delete() throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
    private struct KeychainError: LocalizedError {
        let code: OSStatus
        init(_ code: OSStatus) { self.code = code }
        var errorDescription: String? { "키체인 작업을 완료하지 못했습니다 (\(code))." }
    }
}
