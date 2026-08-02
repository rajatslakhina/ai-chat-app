import Foundation
import Security

/// Every way the Keychain can refuse, surfaced instead of swallowed.
///
/// `SecItemAdd` and friends return an `OSStatus` that is easy to ignore. Ignoring it is how an
/// app ends up believing it stored a key that it did not, then failing one screen later with an
/// error that points nowhere near the cause.
enum KeychainError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    case dataCorrupted(account: String)

    var description: String {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain returned OSStatus \(status): \(message)"
        case let .dataCorrupted(account):
            return "the value stored for \(account) is not valid UTF-8"
        }
    }
}

/// Reads and writes short secrets in the Keychain.
///
/// A protocol rather than a concrete type because the test suite must not touch the real
/// Keychain: on a simulator it is shared between test runs, so a leaked write from one test
/// changes what a later test sees. `InMemoryKeychain` is the substitute.
protocol SecretStoring: Sendable {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// The four `Security` entry points this store calls, behind a protocol.
///
/// Not indirection for its own sake. `SecItemUpdate` and `SecItemDelete` report failure only by
/// returning an `OSStatus`, and there is no way to ask the real Keychain for one on demand — so
/// without a seam the two `throw KeychainError.unexpectedStatus` branches, which are the entire
/// reason this type exists rather than a `try?` at the call site, could never be executed by a
/// test. An error path nobody has run is a guess about what the app does when the Keychain says no.
protocol SecItemPerforming: Sendable {
    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

/// The Security framework itself. Nothing here decides anything; it exists so that everything
/// which *does* decide sits on the testable side of the seam.
struct LiveSecItems: SecItemPerforming {
    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(attributes, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

/// The real Keychain, scoped to this app's service identifier.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is deliberate: the key must survive a
/// relaunch in the background, must never sync to iCloud, and must never ride a backup onto a
/// different device.
struct KeychainStore: SecretStoring {
    let service: String
    private let items: any SecItemPerforming

    init(
        service: String = "com.rajatslakhina.aichatapp.secrets",
        items: any SecItemPerforming = LiveSecItems()
    ) {
        self.service = service
        self.items = items
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func string(for account: String) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = items.copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainError.dataCorrupted(account: account) }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted(account: account)
        }
        return value
    }

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: account)

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = items.update(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = items.add(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(_ account: String) throws {
        let status = items.delete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// A Keychain that refuses every write, for the UI-test launch that has to show what the user is
/// told when it does.
///
/// Ships in `Sources` for the same reason `InMemoryKeychain`, `StaticModelCatalog` and
/// `UnavailableBiometrics` do: a XCUITest launches the app as its own process with no test code
/// linked, so a seam it needs has to be inside the app. The error copy in Settings is the only
/// thing standing between a failed write and a user who believes their key was saved, and until
/// something can make the write fail, nobody has ever seen it.
struct RejectingKeychain: SecretStoring {
    /// `errSecInteractionNotAllowed` — what a protected item returns while the device is locked.
    let status: OSStatus = errSecInteractionNotAllowed

    func string(for account: String) throws -> String? { nil }

    func set(_ value: String, for account: String) throws {
        throw KeychainError.unexpectedStatus(status)
    }

    func remove(_ account: String) throws {
        throw KeychainError.unexpectedStatus(status)
    }
}

/// A Keychain substitute for tests and for UI-test launches, which must be deterministic.
final class InMemoryKeychain: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    func string(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func set(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
    }

    func remove(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
