import XCTest
@testable import SomaRelay

/// A passkey that gives whatever PRF outputs the test chose.
private nonisolated struct StubPasskeys: PasskeyProviding {
    var id = Data(repeating: 0xB2, count: 16)
    var prfFirst: Data? = Data(repeating: 0x11, count: 32)
    var prfSecond: Data? = Data(repeating: 0x22, count: 32)

    func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration {
        PasskeyRegistration(credentialID: id, prfSupported: prfSecond != nil)
    }

    func assert(credentialID: Data?, allowCrossDevice: Bool) async throws -> PasskeyAssertion {
        PasskeyAssertion(credentialID: id, prfFirst: prfFirst, prfSecond: prfSecond)
    }
}

@MainActor
final class VaultSyncTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let oldCredential = Data(repeating: 0xA1, count: 16)

    private let realService = VaultSync.keychainService

    override func setUpWithError() throws {
        // A scratch Keychain item: the app's own vault key is never touched.
        VaultSync.keychainService = "me.somalabs.relay.vault.tests." + UUID().uuidString
        suite = "vaultsync-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        VaultSync.deleteKey()
        // An unsigned build (CODE_SIGNING_ALLOWED=NO) has no Keychain entitlement:
        // every SecItem call answers errSecMissingEntitlement (-34018). Skip rather
        // than fail; the default simulator signing ("Sign to Run Locally") runs them.
        let probe = VaultSync.storeKey(Data(repeating: 0, count: 32))
        VaultSync.deleteKey()
        if probe == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in an unsigned test host (-34018). Run with code signing.")
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        VaultSync.deleteKey()
        VaultSync.keychainService = realService
    }

    private func lock() -> LockController {
        LockController(passkeys: StubPasskeys(), device: FakeDeviceAuth(succeeds: true), defaults: defaults)
    }

    // MARK: (a) init resurrection

    func testOrphanKeychainKeyWithoutCredentialIsDeletedAndStaysOff() {
        // Reinstall: UserDefaults wiped, Keychain kept.
        XCTAssertEqual(VaultSync.storeKey(Data(repeating: 7, count: 32)), errSecSuccess)
        let sync = VaultSync(passkeys: StubPasskeys(), defaults: defaults, lock: lock())
        XCTAssertEqual(sync.status, .off)
        XCTAssertFalse(defaults.bool(forKey: VaultSync.enabledKey))
        XCTAssertFalse(VaultSync.keyExists(), "the orphan key is gone")
    }

    func testKeychainKeyWithCredentialIsResurrected() {
        let lock = lock()
        lock.storeCredential(id: oldCredential)
        XCTAssertEqual(VaultSync.storeKey(Data(repeating: 7, count: 32)), errSecSuccess)
        let sync = VaultSync(passkeys: StubPasskeys(), defaults: defaults, lock: lock)
        XCTAssertEqual(sync.status, .pending)
        XCTAssertTrue(defaults.bool(forKey: VaultSync.enabledKey))
        XCTAssertTrue(VaultSync.keyExists())
    }

    // MARK: (b) setUp ordering

    func testBadPRFLeavesNoNewCredentialAndKeepsTheOldPair() async throws {
        // The model first: its own VaultSync (on .standard) runs before the scratch key exists.
        let model = AppModel()
        model.adoptCore(RelayCoreFactory.create(displayName: "Test"))
        let lock = lock()
        lock.storeCredential(id: oldCredential)
        let oldKey = Data(repeating: 7, count: 32)
        XCTAssertEqual(VaultSync.storeKey(oldKey), errSecSuccess)
        let sync = VaultSync(passkeys: StubPasskeys(prfSecond: Data(repeating: 0x22, count: 5)), defaults: defaults, lock: lock)
        sync.model = model
        do {
            _ = try await sync.setUp(userName: "test")
            XCTFail("badPRF expected")
        } catch let error as VaultSync.SetupError {
            XCTAssertEqual(error, .badPRF)
        }
        XCTAssertEqual(lock.credentialID, oldCredential, "the new credential id was not stored")
        XCTAssertTrue(VaultSync.keyExists(), "the old key is still there")
        guard case .found(let kept) = VaultSync.readKey() else { return XCTFail("key unreadable") }
        XCTAssertEqual(kept, oldKey)
        XCTAssertTrue(defaults.bool(forKey: VaultSync.enabledKey), "the old pair is still on")
    }

    func testBadPRFOnFirstSetupStoresNoCredentialAtAll() async throws {
        let lock = lock()
        let model = AppModel()
        model.adoptCore(RelayCoreFactory.create(displayName: "Test"))
        let sync = VaultSync(passkeys: StubPasskeys(prfSecond: Data(repeating: 0x22, count: 5)), defaults: defaults, lock: lock)
        sync.model = model
        _ = try? await sync.setUp(userName: "test")
        XCTAssertNil(lock.credentialID)
        XCTAssertEqual(sync.status, .off)
        XCTAssertFalse(VaultSync.keyExists())
        XCTAssertFalse(defaults.bool(forKey: VaultSync.enabledKey))
    }
}
