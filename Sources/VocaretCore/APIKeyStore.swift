import Foundation
import Security

enum APIProvider: String, Sendable {
    case soniox
    case openAI = "openai"
}

enum APIKeyStoreError: Error, Equatable, LocalizedError {
    case emptyValue
    case invalidStoredValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyValue:
            "API keys cannot be empty."
        case .invalidStoredValue:
            "The stored API key is not valid UTF-8."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

protocol APIKeyStoring: Sendable {
    func load(_ provider: APIProvider) throws -> String?
    func save(_ value: String, for provider: APIProvider) throws
    func remove(_ provider: APIProvider) throws
}

struct KeychainClient: @unchecked Sendable {
    let copyMatching: ([String: Any]) -> (OSStatus, Data?)
    let update: ([String: Any], [String: Any]) -> OSStatus
    let add: ([String: Any]) -> OSStatus
    let delete: ([String: Any]) -> OSStatus

    static let system = KeychainClient(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { item in
            SecItemAdd(item as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

struct KeychainAPIKeyStore: APIKeyStoring {
    static let shared = KeychainAPIKeyStore()

    private let service: String
    private let client: KeychainClient
    private let fallback: any APIKeyStoring

    init(
        service: String = "com.jancuhel.vocaret.api-key",
        client: KeychainClient = .system,
        fallback: any APIKeyStoring = FileAPIKeyStore.shared
    ) {
        self.service = service
        self.client = client
        self.fallback = fallback
    }

    func load(_ provider: APIProvider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.copyMatching(query)

        switch status {
        case errSecItemNotFound, errSecMissingEntitlement:
            return try fallback.load(provider)
        case errSecSuccess:
            guard let data,
                  let value = String(data: data, encoding: .utf8) else {
                throw APIKeyStoreError.invalidStoredValue
            }
            return value
        default:
            throw APIKeyStoreError.keychain(status)
        }
    }

    func save(_ value: String, for provider: APIProvider) throws {
        let trimmed = try Self.normalized(value)
        let data = Data(trimmed.utf8)
        let attributes = [kSecValueData as String: data]

        let updateStatus = client.update(baseQuery(for: provider), attributes)
        if updateStatus == errSecMissingEntitlement {
            try fallback.save(trimmed, for: provider)
            return
        }
        if updateStatus != errSecItemNotFound && updateStatus != errSecSuccess {
            throw APIKeyStoreError.keychain(updateStatus)
        }
        if updateStatus == errSecItemNotFound {
            var item = baseQuery(for: provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = client.add(item)
            if addStatus == errSecMissingEntitlement {
                try fallback.save(trimmed, for: provider)
                return
            }
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.keychain(addStatus)
            }
        }
        try? fallback.remove(provider)
    }

    func remove(_ provider: APIProvider) throws {
        let status = client.delete(baseQuery(for: provider))
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw APIKeyStoreError.keychain(status)
        }
        try fallback.remove(provider)
    }

    func baseQuery(for provider: APIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            // The legacy file-based macOS Keychain can synchronously wait for
            // SecurityAgent. Never send this query through that shim.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    fileprivate static func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyStoreError.emptyValue }
        return trimmed
    }
}

/// SwiftPM ad-hoc bundles do not have a provisioning profile, so macOS denies
/// their Data Protection Keychain access. Keep that development-only fallback
/// out of preferences and restrict both its directory and file to this user.
final class FileAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    static let shared = FileAPIKeyStore(
        directory: SettingsStore.shared.appSupportDir
            .appendingPathComponent("Secrets", isDirectory: true)
    )

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(for provider: APIProvider) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).key", isDirectory: false)
    }

    func load(_ provider: APIProvider) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidStoredValue
        }
        return value
    }

    func save(_ value: String, for provider: APIProvider) throws {
        let trimmed = try KeychainAPIKeyStore.normalized(value)
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = fileURL(for: provider)
        try Data(trimmed.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    func remove(_ provider: APIProvider) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: provider)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Runs the synchronous Security.framework API away from UI and actor
/// executors. Keychain calls are documented blocking calls, and the local
/// protected-file fallback also performs synchronous I/O.
struct AsyncAPIKeyAccess: Sendable {
    static let shared = AsyncAPIKeyAccess(store: KeychainAPIKeyStore.shared)

    let store: any APIKeyStoring

    func load(_ provider: APIProvider) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try store.load(provider)
        }.value
    }

    func save(_ value: String, for provider: APIProvider) async throws {
        try await Task.detached(priority: .userInitiated) {
            try store.save(value, for: provider)
        }.value
    }

    func remove(_ provider: APIProvider) async throws {
        try await Task.detached(priority: .userInitiated) {
            try store.remove(provider)
        }.value
    }
}

final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [APIProvider: String] = [:]

    func load(_ provider: APIProvider) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[provider]
    }

    func save(_ value: String, for provider: APIProvider) throws {
        let trimmed = try KeychainAPIKeyStore.normalized(value)
        lock.lock()
        defer { lock.unlock() }
        values[provider] = trimmed
    }

    func remove(_ provider: APIProvider) throws {
        lock.lock()
        defer { lock.unlock() }
        values[provider] = nil
    }
}
