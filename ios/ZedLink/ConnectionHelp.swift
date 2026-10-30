import Foundation

struct ConnectionHelp: Equatable {
    enum Action: Equatable { case retry, connections }
    let title: String
    let detail: String
    let action: Action
    static func forMessage(_ message: String) -> ConnectionHelp? {
        switch message {
        case "No network connection. Check the phone's network settings.":
            return .init(title: "Phone is offline", detail: "Restore Wi-Fi or cellular access, then reconnect. Your Agent keeps running in desktop Zed.", action: .retry)
        case "Gateway name could not be resolved. Check the saved hostname and VPN DNS route.":
            return .init(title: "Hostname lookup failed", detail: "Check the saved HTTPS hostname and your VPN's DNS connection.", action: .connections)
        case "Gateway request timed out. Check the phone's private route and retry.",
             "Could not connect to the gateway. Check the private route and address.",
             "Gateway connection dropped. Check the phone's private route and retry.":
            return .init(title: "Gateway cannot be reached", detail: "Open the saved HTTPS address in Safari. If Safari cannot find the server, check the VPN DNS route. If it times out, check that the private VPN route is passing traffic on this Wi-Fi. The app will retry while open.", action: .retry)
        case "HTTPS identity could not be verified. Check the hostname and certificate.", GatewayFailure.changedIdentity.localizedDescription:
            return .init(title: "Connection identity needs review", detail: "Check the hostname, certificate and gateway identity before pairing again. TLS verification stays enabled.", action: .connections)
        case "Pair this device first.", GatewayFailure.native("UNAUTHENTICATED").localizedDescription:
            return .init(title: "Device needs pairing", detail: "Open Connections and pair with a new code from your workstation.", action: .connections)
        case GatewayFailure.native("INSTANCE_UNAVAILABLE").localizedDescription:
            return .init(title: "Desktop Zed is unavailable", detail: "Open patched Zed and enable ZedLink for the intended workspace, then reconnect.", action: .retry)
        case GatewayFailure.native("THREAD_NOT_EXPOSED").localizedDescription, "The selected thread is no longer exposed in desktop Zed.":
            return .init(title: "Session is no longer exposed", detail: "Use /remote-control in desktop Zed to expose this conversation again, or select another session.", action: .retry)
        case GatewayFailure.redirected.localizedDescription, GatewayFailure.invalidEndpoint.localizedDescription:
            return .init(title: "Saved address needs review", detail: "Use the gateway's trusted HTTPS address. Redirects and unapproved alternate routes are not followed.", action: .connections)
        default: return nil
        }
    }
}
