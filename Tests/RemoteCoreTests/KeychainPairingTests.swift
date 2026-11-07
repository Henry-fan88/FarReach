import XCTest
import Security
@testable import RemoteCore

/// Explicitly opt in because this exercises the real local login Keychain.
/// The test never accesses the application's production Keychain namespace.
final class KeychainPairingTests: XCTestCase {
    func testClassicKeychainPersistsIdentityAndTrustedDevice() throws {
        guard ProcessInfo.processInfo.environment["FARREACH_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set FARREACH_TEST_KEYCHAIN=1 to test disposable records in the real macOS login Keychain.")
        }
        let namespace = "org.farreach.tests." + UUID().uuidString.lowercased()
        let identityService = namespace + ".identity"
        let deviceService = namespace + ".devices"
        let trustedIdentity = DeviceIdentity()
        let trustedID = trustedIdentity.id
        var previousInteraction: DarwinBoolean = false
        let previousStatus = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        guard previousStatus == errSecSuccess else { throw DevicePairingError.keychain(previousStatus) }
        let disabled = SecKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { throw DevicePairingError.keychain(disabled) }
        defer {
            // Delete only this run's exact accounts, never a service-wide query
            // and never org.farreach.mac.* application items.
            for (service, account) in [(identityService, "local"), (deviceService, trustedID)] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecUseDataProtectionKeychain as String: false,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                let status = SecItemDelete(query as CFDictionary)
                XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound,
                              "Could not remove an exact disposable Keychain test item (status \(status)).")
            }
            XCTAssertEqual(SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue), errSecSuccess)
        }

        let originalStore = KeychainPairingStore(namespace: namespace)
        XCTAssertTrue(try originalStore.listDevices().isEmpty)
        let originalIdentity = try originalStore.loadOrCreateIdentity()
        let trusted = try PairedDevice(name: "Disposable FarReach test device", publicKey: trustedIdentity.publicKey,
                                       lastSeen: Date(timeIntervalSince1970: 100))
        try originalStore.save(trusted)

        // A fresh store has no cached private identity or trusted-device state.
        let freshStore = KeychainPairingStore(namespace: namespace)
        let restoredIdentity = try freshStore.loadOrCreateIdentity()
        XCTAssertEqual(restoredIdentity.id, originalIdentity.id)
        XCTAssertEqual(restoredIdentity.publicKey, originalIdentity.publicKey)
        XCTAssertEqual(try freshStore.listDevices(), [trusted])

        var updated = trusted
        updated.name = "Updated disposable test device"
        updated.lastSeen = Date(timeIntervalSince1970: 200)
        try freshStore.save(updated)
        let thirdStore = KeychainPairingStore(namespace: namespace)
        XCTAssertEqual(try thirdStore.listDevices(), [updated])
        try thirdStore.forget(id: trusted.id)
        XCTAssertTrue(try originalStore.listDevices().isEmpty)
        XCTAssertEqual(try thirdStore.loadOrCreateIdentity().id, originalIdentity.id,
                       "Revoking a peer must not change the persistent local identity.")
    }
}
