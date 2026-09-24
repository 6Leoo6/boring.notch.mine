//
//  AgentBridgeServer.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation
import Network

/// Loopback HTTP endpoint the `boringnotch-mcp` helper talks to.
///
/// The MCP protocol itself lives in the helper, not here. The app is sandboxed, so it cannot
/// read or write the paths an agent names; the helper runs unsandboxed as the agent's child
/// and does the file I/O, and this side only moves bytes in and out of the live shelf and
/// clipboard state. Serving from inside the app is also the only way to reach that state
/// without another process reading this app's container, which macOS gates behind a
/// per-access "access data from other apps" prompt.
///
/// Discovery is a file outside the container (`~/.config/boringnotch/agent-bridge.json`,
/// granted by a home-relative entitlement) holding the port and a token minted per start, so
/// the helper needs no configuration and a stale token dies with the app.
@MainActor
final class AgentBridgeServer: ObservableObject {
    static let shared = AgentBridgeServer()

    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private var token = ""
    private let queue = DispatchQueue(label: "boringNotch.agentBridge")

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AgentBridgeDiscovery.remove() }
        }
    }

    func startIfEnabled() {
        setEnabled(Defaults[.agentBridgeEnabled])
    }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        token = Self.makeToken()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let token = self.token
        listener.newConnectionHandler = { [queue] connection in
            BridgeConnection(connection: connection, token: token, queue: queue).start()
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            Task { @MainActor in
                // A stop/start in quick succession leaves the old listener still reporting
                guard let self, let listener, self.listener === listener else { return }
                self.listenerStateChanged(newState)
            }
        }
        self.listener = listener
        state = .starting
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AgentBridgeDiscovery.remove()
        state = .stopped
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            if let error = AgentBridgeDiscovery.write(port: port, token: token) {
                state = .failed("Could not write \(AgentBridgeDiscovery.displayPath): \(error)")
            } else {
                state = .listening(port: port)
            }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            AgentBridgeDiscovery.remove()
            state = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Discovery file

enum AgentBridgeDiscovery {
    static let displayPath = "~/.config/boringnotch/agent-bridge.json"

    /// The REAL home. Inside the sandbox `NSHomeDirectory()` is the container, which is
    /// exactly where the helper must not have to look.
    private static var directory: URL {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config/boringnotch", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("agent-bridge.json") }

    static func write(port: UInt16, token: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let payload: [String: Any] = [
                "port": Int(port),
                "token": token,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "version": 1,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            // Created 0600 before the token is written, so there is no window where it is readable
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - HTTP connection

/// One request per connection, then close. The helper opens a fresh connection per tool
/// call, so keep-alive would buy nothing and cost a state machine.
private final class BridgeConnection: @unchecked Sendable {
    /// Base64 inflates by 4/3; this admits the router's 64 MB payload cap with headroom.
    private static let maxBodyBytes = 96 * 1024 * 1024
    private static let maxHeaderBytes = 16 * 1024

    private let connection: NWConnection
    private let token: String
    private let queue: DispatchQueue
    private var buffer = Data()
    private var selfRetain: BridgeConnection?

    init(connection: NWConnection, token: String, queue: DispatchQueue) {
        self.connection = connection
        self.token = token
        self.queue = queue
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.selfRetain = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil { return self.close() }
            if self.tryHandle() { return }
            if isComplete { return self.respond(status: 400, json: Self.errorBody("Incomplete request")) }
            self.receive()
        }
    }

    /// True once a response has been sent (or is being produced).
    private func tryHandle() -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > Self.maxHeaderBytes {
                respond(status: 431, json: Self.errorBody("Headers too large"))
                return true
            }
            return false
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            respond(status: 400, json: Self.errorBody("Bad headers"))
            return true
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard requestLine.count >= 2, requestLine[0] == "POST", requestLine[1] == "/rpc" else {
            respond(status: 404, json: Self.errorBody("Only POST /rpc is served"))
            return true
        }
        // A browser page can reach loopback; it can never omit Origin, so refusing any
        // request that carries one closes that door regardless of the token.
        guard headers["origin"] == nil else {
            respond(status: 403, json: Self.errorBody("Browser requests are not accepted"))
            return true
        }
        guard let auth = headers["authorization"], Self.constantTimeEquals(auth, "Bearer \(token)") else {
            respond(status: 401, json: Self.errorBody("Bad or missing token"))
            return true
        }
        guard let lengthString = headers["content-length"], let length = Int(lengthString), length >= 0 else {
            respond(status: 411, json: Self.errorBody("Content-Length required"))
            return true
        }
        guard length <= Self.maxBodyBytes else {
            respond(status: 413, json: Self.errorBody("Request body too large"))
            return true
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return false }

        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer = Data()
        Task {
            let reply = await AgentBridgeRouter.respond(to: body)
            self.queue.async { self.respond(status: 200, json: reply) }
        }
        return true
    }

    private func respond(status: Int, json: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Bad Request"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        connection.cancel()
        selfRetain = nil
    }

    private static func errorBody(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
