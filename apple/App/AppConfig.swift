import Foundation

/// App-wide constants. The default relay node lives here and only here.
nonisolated enum AppConfig {
    /// Default relay node: the public test node on an Azure VM with persistent storage and a TURN server (Soma Labs).
    static let defaultNodeURL = "https://hushrelay.app"

    static var defaultNodeHost: String { URL(string: defaultNodeURL)?.host() ?? "hushrelay.app" }

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
