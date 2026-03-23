import Foundation
import os
import Security

protocol KeychainStoreProtocol {
    func read(account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))"
        case .invalidValue:
            "Stored API key could not be decoded."
        }
    }
}

final class KeychainStore: KeychainStoreProtocol {
    private static let logger = Logger(subsystem: "com.porch.app", category: "Keychain")
    private let service: String

    init(service: String = "steven.Porch") {
        self.service = service
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                Self.logger.error("[read] account=\(account, privacy: .public) error=invalidValue")
                throw KeychainStoreError.invalidValue
            }
            Self.logger.debug("[read] account=\(account, privacy: .public) found=true")
            return value
        case errSecItemNotFound:
            Self.logger.debug("[read] account=\(account, privacy: .public) found=false")
            return nil
        default:
            Self.logger.error("[read] account=\(account, privacy: .public) osStatus=\(status)")
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            Self.logger.info("[save] account=\(account, privacy: .public) action=updated")
            return
        }
        if updateStatus != errSecItemNotFound {
            Self.logger.error("[save] account=\(account, privacy: .public) updateOSStatus=\(updateStatus)")
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.logger.error("[save] account=\(account, privacy: .public) addOSStatus=\(addStatus)")
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
        Self.logger.info("[save] account=\(account, privacy: .public) action=created")
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("[delete] account=\(account, privacy: .public) osStatus=\(status)")
            throw KeychainStoreError.unexpectedStatus(status)
        }
        Self.logger.info("[delete] account=\(account, privacy: .public)")
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
