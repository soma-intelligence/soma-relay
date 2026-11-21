import CryptoKit
import Foundation

/// Mailbox id = first 16 bytes of SHA3-256("soma-relay/mailbox" || fingerprint) (spec section 4).
nonisolated enum MailboxHash {
    static func mailbox(fp: String, mock: Bool) -> String {
        if mock { return MockRelayCore.mailbox(fp) }
        var input = Data("soma-relay/mailbox".utf8)
        input.append(Data(hex: fp) ?? Data())
        return Data(SHA3_256.hash(data: input)).prefix(16).hex
    }
}
