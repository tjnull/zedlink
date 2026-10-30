import Foundation

enum GatewayFailure: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case changedIdentity
    case redirected
    case status(Int)
    case native(String)

    var isTransientRouteFailure: Bool {
        guard case .native(let message) = self else { return false }
        return [
            "No network connection. Check the phone's network settings.",
            "Gateway name could not be resolved. Check the saved hostname and VPN DNS route.",
            "Gateway request timed out. Check the phone's private route and retry.",
            "Could not connect to the gateway. Check the private route and address.",
            "Gateway connection dropped. Check the phone's private route and retry."
        ].contains(message)
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS address without credentials, query, or fragment."
        case .invalidResponse: "The gateway sent an unexpected response."
        case .changedIdentity: "Gateway identity changed. No device credential was sent."
        case .redirected: "The endpoint redirected. Check the saved address before reconnecting."
        case .status(let status): "Gateway returned HTTP \(status)."
        case .native(let code):
            switch code {
            case "UNAUTHENTICATED": "Device pairing is missing or revoked."
            case "THREAD_NOT_EXPOSED": "This thread is no longer exposed in desktop Zed."
            case "INSTANCE_UNAVAILABLE": "Desktop Zed is unavailable."
            case "RESYNC_REQUIRED": "Event history changed; refreshing the native snapshot."
            default: code
            }
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct GatewayClient {
    private static let redirectDelegate = NoRedirect()
    private static let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    private static func identitySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // An explicit endpoint test must finish with a result even when a VPN route is absent.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }
    let profile: ConnectionProfile
    let token: String?
    var targetID: String? = nil

    private var base: URL {
        get throws {
            guard let url = URL(string: profile.endpoint),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host != nil,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil else {
                throw GatewayFailure.invalidEndpoint
            }
            return url
        }
    }

    private func address(_ path: String) throws -> URL {
        let root = try base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let result = URL(string: root + path) else { throw GatewayFailure.invalidEndpoint }
        return result
    }

    private func call(_ path: String, payload: [String: Any]? = nil, authorized: Bool = false,
                      method: String? = nil, freshTransport: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: try address(path))
        request.timeoutInterval = freshTransport ? 20 : 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method ?? (payload == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let token else { throw GatewayFailure.native("UNAUTHENTICATED") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        // Identity checks are small, unauthenticated reads. A fresh URLSession avoids
        // reusing a connection created before an iPhone VPN route changed.
        let transport = freshTransport ? Self.identitySession() : Self.session
        defer { if freshTransport { transport.finishTasksAndInvalidate() } }
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet:
                throw GatewayFailure.native("No network connection. Check the phone's network settings.")
            case .cannotFindHost, .dnsLookupFailed:
                throw GatewayFailure.native("Gateway name could not be resolved. Check the saved hostname and VPN DNS route.")
            case .timedOut:
                throw GatewayFailure.native("Gateway request timed out. Check the phone's private route and retry.")
            case .cannotConnectToHost:
                throw GatewayFailure.native("Could not connect to the gateway. Check the private route and address.")
            case .networkConnectionLost:
                throw GatewayFailure.native("Gateway connection dropped. Check the phone's private route and retry.")
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                throw GatewayFailure.native("HTTPS identity could not be verified. Check the hostname and certificate.")
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayFailure.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw GatewayFailure.redirected }
        guard data.count <= 4_194_304,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayFailure.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw GatewayFailure.native(object["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return object
    }

    func gatewayID() async throws -> String {
        let object = try await call("/v1/gateway", freshTransport: true)
        guard object["version"] as? Int == 1, let id = object["gateway_id"] as? String else {
            throw GatewayFailure.invalidResponse
        }
        return id
    }

    func verifyIdentity() async throws {
        guard try await gatewayID() == profile.gatewayID else { throw GatewayFailure.changedIdentity }
    }

    func pair(code: String, deviceName: String) async throws -> (deviceID: String, token: String) {
        try await verifyIdentity()
        let object = try await call("/v1/pair", payload: ["code": code, "device_name": deviceName])
        guard object["gateway_id"] as? String == profile.gatewayID,
              let deviceID = object["device_id"] as? String,
              let token = object["token"] as? String, token.count == 64 else {
            throw GatewayFailure.invalidResponse
        }
        return (deviceID, token)
    }

    func rpc(_ method: String, params: [String: Any] = [:], requestID: String = UUID().uuidString) async throws -> [String: Any] {
        // Recheck before every authenticated call. A changed endpoint never receives the token.
        try await verifyIdentity()
        var envelope: [String: Any] = ["version": 1, "request_id": requestID, "method": method, "params": params]
        if method != "instance.list", let targetID { envelope["target_id"] = targetID }
        let object = try await call("/v1/rpc", payload: envelope, authorized: true)
        guard object["version"] as? Int == 1, object["request_id"] as? String == requestID else {
            throw GatewayFailure.invalidResponse
        }
        if let error = object["error"] as? [String: Any], let code = error["code"] as? String {
            throw GatewayFailure.native(code)
        }
        guard let result = object["result"] as? [String: Any] else { throw GatewayFailure.invalidResponse }
        return result
    }

    func apnsStatus() async throws -> (supported: Bool, enabled: Bool) {
        try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", authorized: true)
        guard let supported = result["supported"] as? Bool,
              let enabled = result["enabled"] as? Bool else { throw GatewayFailure.invalidResponse }
        return (supported, enabled)
    }

    func registerAPNs(token: String, environment: String) async throws {
        try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", payload: ["token": token, "environment": environment], authorized: true)
        guard result["enabled"] as? Bool == true else { throw GatewayFailure.invalidResponse }
    }

    func unregisterAPNs() async throws {
        try await verifyIdentity()
        let result = try await call("/v1/notifications/apns", authorized: true, method: "DELETE")
        guard result["enabled"] as? Bool == false else { throw GatewayFailure.invalidResponse }
    }

    func testAPNs() async throws {
        try await verifyIdentity()
        let result = try await call("/v1/notifications/apns/test", payload: [:], authorized: true)
        guard result["delivered"] as? Bool == true else { throw GatewayFailure.invalidResponse }
    }

    func eventStream(threadID: String, afterSequence: Int) throws -> AsyncThrowingStream<[String: Any], Error> {
        guard let token else { throw GatewayFailure.native("Pair this device first.") }
        guard var components = URLComponents(string: profile.endpoint), components.scheme == "https" else {
            throw GatewayFailure.native("ZedLink requires trusted HTTPS.")
        }
        components.scheme = "wss"
        components.path = "/v1/events"
        components.queryItems = [
            URLQueryItem(name: "thread_id", value: threadID),
            URLQueryItem(name: "after_sequence", value: String(afterSequence)),
        ] + (targetID.map { [URLQueryItem(name: "target_id", value: $0)] } ?? [])
        guard let url = components.url else { throw GatewayFailure.invalidResponse }
        let task = Self.session.webSocketTask(with: url, protocols: ["zedlink-v1", "zedlink-token-\(token)"])
        task.maximumMessageSize = 4_194_304
        return AsyncThrowingStream { continuation in
            task.resume()
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    if Task.isCancelled { return }
                    let timeout = Task {
                        // A native Zed probe may take up to six seconds. Allow for
                        // transport scheduling without treating a slow turn as a
                        // dead gateway connection.
                        try? await Task.sleep(for: .seconds(12))
                        if Task.isCancelled { return }
                        continuation.finish(throwing: GatewayFailure.native("Gateway event stream timed out."))
                        task.cancel(with: .goingAway, reason: nil)
                    }
                    task.sendPing { error in
                        timeout.cancel()
                        if let error {
                            continuation.finish(throwing: error)
                            task.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            }
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GatewayFailure.invalidResponse }
                        if let error = envelope["error"] as? [String: Any], let code = error["code"] as? String { throw GatewayFailure.native(code) }
                        guard let result = envelope["result"] as? [String: Any] else { throw GatewayFailure.invalidResponse }
                        continuation.yield(result)
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                receiver.cancel(); heartbeat.cancel(); task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
