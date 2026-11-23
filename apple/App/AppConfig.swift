import Foundation

/// App-wide constants. The default relay node lives here and only here.
nonisolated enum AppConfig {
    /// Default relay node: the public test node on an Azure VM with persistent storage and a TURN server (Soma Labs).
    /// hushrelay.app becomes the default only once its DNS and TLS are live (ship step); both names serve the same node.
    static let defaultNodeURL = "https://somarelay.westus2.cloudapp.azure.com"

    static var defaultNodeHost: String { URL(string: defaultNodeURL)?.host() ?? "somarelay.westus2.cloudapp.azure.com" }

    /// Base of the encrypted SMS fallback link: `<active node>/m#<base64url envelope>`.
    static func smsLinkBase(nodeURL: String) -> String {
        (nodeURL.hasSuffix("/") ? String(nodeURL.dropLast()) : nodeURL) + "/m#"
    }

    /// Demo data and debug screens exist only in Debug builds.
    static var demoAllowed: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
