import XCTest
import Security
@testable import VocaretCore

final class APIKeyStoreTests: XCTestCase {
    func testInMemorySecretStoreReplacesAndRemovesKey() throws {
        let secrets = InMemoryAPIKeyStore()

        try secrets.save("one", for: .soniox)
        try secrets.save("  two  ", for: .soniox)
        XCTAssertEqual(try secrets.load(.soniox), "two")

        try secrets.remove(.soniox)
        XCTAssertNil(try secrets.load(.soniox))
    }

    func testProvidersKeepSeparateKeys() throws {
        let secrets = InMemoryAPIKeyStore()

        try secrets.save("soniox-secret", for: .soniox)
        try secrets.save("openai-secret", for: .openAI)

        XCTAssertEqual(try secrets.load(.soniox), "soniox-secret")
        XCTAssertEqual(try secrets.load(.openAI), "openai-secret")
    }

    func testSecretStoreRejectsEmptyKey() {
        let secrets = InMemoryAPIKeyStore()

        XCTAssertThrowsError(try secrets.save("  \n", for: .soniox)) { error in
            XCTAssertEqual(error as? APIKeyStoreError, .emptyValue)
        }
    }

    func testKeychainQueriesUseTheDataProtectionKeychain() {
        let store = KeychainAPIKeyStore(service: "com.jancuhel.vocaret.tests.\(UUID().uuidString)")

        let query = store.baseQuery(for: .soniox)

        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    func testMissingKeychainEntitlementUsesProtectedLocalFallback() throws {
        let fallback = InMemoryAPIKeyStore()
        let client = KeychainClient(
            copyMatching: { _ in (errSecMissingEntitlement, nil) },
            update: { _, _ in errSecMissingEntitlement },
            add: { _ in errSecMissingEntitlement },
            delete: { _ in errSecMissingEntitlement }
        )
        let subject = KeychainAPIKeyStore(
            service: "com.jancuhel.vocaret.tests.\(UUID().uuidString)",
            client: client,
            fallback: fallback
        )

        try subject.save("secret", for: .soniox)

        XCTAssertEqual(try fallback.load(.soniox), "secret")
        XCTAssertEqual(try subject.load(.soniox), "secret")
    }

    func testLocalFallbackRestrictsDirectoryAndFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocaret-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileAPIKeyStore(directory: directory)

        try store.save("secret", for: .soniox)

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: .soniox).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((directoryMode?.intValue ?? 0) & 0o777, 0o700)
        XCTAssertEqual((fileMode?.intValue ?? 0) & 0o777, 0o600)
    }

    @MainActor
    func testAsyncAccessRunsBlockingSecretStoreOffTheMainThread() async throws {
        let blockingStore = ThreadRecordingSecretStore()
        let access = AsyncAPIKeyAccess(store: blockingStore)

        try await access.save("secret", for: .soniox)

        XCTAssertFalse(blockingStore.saveRanOnMainThread)
    }
}

private final class ThreadRecordingSecretStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _saveRanOnMainThread: Bool?

    var saveRanOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _saveRanOnMainThread ?? true
    }

    func load(_ provider: APIProvider) throws -> String? { nil }

    func save(_ value: String, for provider: APIProvider) throws {
        lock.lock()
        _saveRanOnMainThread = Thread.isMainThread
        lock.unlock()
    }

    func remove(_ provider: APIProvider) throws {}
}
