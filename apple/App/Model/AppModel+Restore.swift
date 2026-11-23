import Foundation
import RelayCore

/// Why a restore from a passkey did not finish. Nothing on the phone changed in any case.
nonisolated enum PasskeyRestoreError: Error, Equatable, Sendable {
    /// The person closed the passkey sheet.
    case cancelled
    /// No Relay passkey here nor on a nearby device.
    case noPasskey
    /// Passkeys cannot run on this device.
    case unavailable
    /// The node has no vault for this passkey (404).
    case noBackup
    /// The passkey has no PRF, or its key does not open the vault (`Decrypt` and the like).
    case cannotOpen
    /// The node did not answer.
    case network

    /// Text under the restore button; nil when the person cancelled on purpose.
    var message: String? {
        switch self {
        case .cancelled: nil
        case .noPasskey: "Aucun passkey Relay trouvé."
        case .unavailable: "Les passkeys ne sont pas disponibles sur cet appareil."
        case .noBackup: "Aucune sauvegarde pour ce passkey"
        case .cannotOpen: "Ce passkey ne peut pas ouvrir la sauvegarde"
        case .network: "Pas de réseau"
        }
    }
}

extension AppModel {
    static let restoredBanner = "Identité restaurée. Utilise ce téléphone désormais."

    /// Restore on a new phone (spec section 3): a discoverable assertion that may come from
    /// another device, `vault_id` from the credential id, `GET /v1/vault/{id}`, open with
    /// `vault_key`, then the engine and the app settings the vault carried. Everything that can
    /// fail runs before the phone changes, so a failure leaves onboarding as it was.
    /// On success the lock goes on through this same assertion and the backup keeps going.
    func restoreFromPasskey() async throws(PasskeyRestoreError) {
        guard core == nil, usesRealCore else { throw .unavailable }
        let assertion: PasskeyAssertion
        do {
            assertion = try await PasskeyService.current.assert(credentialID: nil, allowCrossDevice: true)
        } catch PasskeyFailure.cancelled {
            throw .cancelled
        } catch PasskeyFailure.noCredential {
            throw .noPasskey
        } catch {
            throw .unavailable
        }
        guard let prfFirst = assertion.prfFirst, let prfSecond = assertion.prfSecond,
              let key = try? vaultKey(prfSecond: prfSecond)
        else { throw .cannotOpen }
        let id = vaultId(credentialId: assertion.credentialID)
        let blob: Data?
        do {
            blob = try await node.getVault(id: id)
        } catch {
            throw .network
        }
        guard let blob else { throw .noBackup }
        guard let plain = try? openVault(key: key, id: id, blob: blob),
              let restored = try? RelayCoreFactory.restore(state: plain.engine)
        else { throw .cannotOpen }
        // An identity appeared meanwhile (file import): leave it alone.
        guard core == nil else { throw .cancelled }
        installRestored(
            restored, handle: plain.handle, nodeURL: plain.nodeUrl,
            channels: try? JSONDecoder().decode([String].self, from: plain.channelsPrefs), photo: plain.photo)

        // The assertion above verified the person: it turns the lock on, no further prompt.
        lock.storeCredential(id: assertion.credentialID)
        if lock.storeCheck(prfFirst: prfFirst), !lock.enabled {
            _ = lock.enable(afterVerifiedAssertion: prfFirst)
        }
        vault.adoptRestored(key: key)
    }
}
