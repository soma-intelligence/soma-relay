import Foundation

/// App-wide constants. The default relay node lives here and only here.
nonisolated enum AppConfig {
    /// Default relay node: the public test node on Azure Container Apps (Soma Labs).
    static let defaultNodeURL = "https://relay-node.graybay-20896372.westus2.azurecontainerapps.io"

    static var defaultNodeHost: String { URL(string: defaultNodeURL)?.host() ?? "relay-node.graybay-20896372.westus2.azurecontainerapps.io" }

    /// Base of the encrypted SMS fallback link: `<defaultNodeURL>/m#<base64url envelope>`.
    static var smsLinkBase: String { defaultNodeURL + "/m#" }

    /// Demo data and debug screens exist only in Debug builds.
    static var demoAllowed: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
