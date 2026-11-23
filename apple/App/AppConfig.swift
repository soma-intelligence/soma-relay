import Foundation

/// App-wide constants. The default relay node lives here and only here.
nonisolated enum AppConfig {
    /// Default relay node: the public test node on an Azure VM with persistent storage and a TURN server (Soma Labs).
    static let defaultNodeURL = "https://hushrelay.app"

    static var defaultNodeHost: String { URL(string: defaultNodeURL)?.host() ?? "hushrelay.app" }

    /// The node every install used before the default moved to `defaultNodeURL`. An install that
    /// already has an identity but never stored a node choice keeps it (`initialNodeURL`).
    static let legacyNodeURL = "https://somarelay.westus2.cloudapp.azure.com"

    /// The node URL at launch. An existing identity with no stored "nodeURL" is pinned to
    /// `legacyNodeURL` once (written to `defaults`), so an update never moves it to a new host.
    /// A fresh install (no identity) takes `defaultNodeURL` and stores nothing.
    static func initialNodeURL(defaults: UserDefaults, hasIdentity: Bool) -> String {
        if let stored = defaults.string(forKey: "nodeURL") { return stored }
        guard hasIdentity else { return defaultNodeURL }
        defaults.set(legacyNodeURL, forKey: "nodeURL")
        return legacyNodeURL
    }

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
