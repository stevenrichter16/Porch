import Foundation
@testable import Porch

enum MemoryKeychainStoreError: LocalizedError, Equatable {
    case forcedReadFailure
    case forcedSaveFailure
    case forcedDeleteFailure

    var errorDescription: String? {
        switch self {
        case .forcedReadFailure:
            "Memory keychain read failed."
        case .forcedSaveFailure:
            "Memory keychain save failed."
        case .forcedDeleteFailure:
            "Memory keychain delete failed."
        }
    }
}

final class MemoryKeychainStore: KeychainStoreProtocol {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    var readError: Error?
    var saveError: Error?
    var deleteError: Error?

    func read(account: String) throws -> String? {
        if let readError {
            throw readError
        }
        return withLock { storage[account] }
    }

    func save(_ value: String, account: String) throws {
        if let saveError {
            throw saveError
        }
        withLock {
            storage[account] = value
        }
    }

    func delete(account: String) throws {
        if let deleteError {
            throw deleteError
        }
        withLock {
            storage.removeValue(forKey: account)
        }
    }

    func storedValue(for account: String) -> String? {
        withLock { storage[account] }
    }

    private func withLock<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}
