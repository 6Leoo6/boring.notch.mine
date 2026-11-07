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

        let method = requestLine.count >= 2 ? String(requestLine[0]) : ""
        let target = requestLine.count >= 2 ? String(requestLine[1]) : ""
        let isBlob = target.hasPrefix("/blob/") && (method == "PUT" || method == "GET")
        guard (method == "POST" && target == "/rpc") || isBlob else {
            respond(status: 404, json: Self.errorBody("Only POST /rpc and PUT/GET /blob/{sha256} are served"))
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
        if isBlob {
            handleBlob(method: method, target: target, headers: headers, bodyStart: headerEnd.upperBound)
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

    private func respond(status: Int, json: Data, drain: Bool = false) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 416: reason = "Range Not Satisfiable"
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
            if drain { self?.drainThenClose() } else { self?.close() }
        })
    }

    private func close() {
        connection.cancel()
        selfRetain = nil
    }

    private static func errorBody(_ message: String, code: String? = nil) -> Data {
        var out: [String: Any] = ["ok": false, "error": message]
        if let code { out["code"] = code }
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
    }

    private static func resultBody(_ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])) ?? Data()
    }

    // MARK: - /blob (hub D-176)

    /// `PUT /blob/{sha256}` streams the body to disk and `GET /blob/{sha256}` streams a file
    /// back, 1 MiB at a time, so neither has the /rpc body cap nor holds a file in memory.
    /// Same loopback, Origin and token rules as /rpc (checked before this is reached).
    private func handleBlob(method: String, target: String, headers: [String: String], bodyStart: Data.Index) {
        guard let sha = HubBlobStore.normalized(String(target.dropFirst("/blob/".count))) else {
            return respond(status: method == "GET" ? 404 : 200,
                           json: Self.errorBody("The path must be /blob/ and a sha256 (64 hex characters)", code: method == "GET" ? "not_found" : "invalid_params"))
        }
        if method == "GET" {
            serveBlob(sha, range: headers["range"])
        } else {
            receiveBlob(sha, headers: headers, bodyStart: bodyStart)
        }
    }

    private func receiveBlob(_ sha: String, headers: [String: String], bodyStart: Data.Index) {
        // An answer before the body was read: drain it a moment so the client sees the reply
        // instead of a reset.
        let early = { (json: Data) in self.respond(status: 200, json: json, drain: true) }
        // No chunked bodies (hub contract): their framing would land in the file.
        guard headers["transfer-encoding"] == nil,
              let lengthString = headers["content-length"], let length = Int64(lengthString), length >= 0 else {
            return respond(status: 411, json: Self.errorBody("Content-Length required, without Transfer-Encoding"), drain: true)
        }
        guard let sizeString = headers["hub-blob-size"], let size = Int64(sizeString) else {
            return early(Self.errorBody("Hub-Blob-Size (the whole blob's size) is required", code: "invalid_params"))
        }
        var offset: Int64 = 0
        if let raw = headers["hub-blob-offset"] {
            guard let value = Int64(raw) else {
                return early(Self.errorBody("Hub-Blob-Offset must be a number", code: "invalid_params"))
            }
            offset = value
        }
        let upload: HubBlobStore.Upload
        do {
            switch try HubBlobStore.shared.begin(sha: sha, size: size, offset: offset, length: length) {
            case .answer(let progress):
                return early(Self.resultBody(progress.json))
            case .upload(let started):
                upload = started
            }
        } catch let failure as HubBlobStore.Failure {
            return early(Self.errorBody(failure.message, code: failure.code))
        } catch {
            return early(Self.errorBody(error.localizedDescription, code: "unavailable"))
        }

        // Body bytes that came in with the headers
        let leftover = buffer[bodyStart...].prefix(Int(min(length, Int64(Int.max))))
        buffer = Data()
        var remaining = length
        if !leftover.isEmpty {
            do { try upload.write(Data(leftover)) } catch { return failUpload(upload, error) }
            remaining -= Int64(leftover.count)
        }
        receiveBody(upload, remaining: remaining)
    }

    /// A stalled upload gives its blob back after this long, so it can't stay busy forever.
    private static let uploadIdleTimeout: TimeInterval = 30

    private func receiveBody(_ upload: HubBlobStore.Upload, remaining: Int64) {
        guard remaining > 0 else { return finishUpload(upload) }
        let maximum = Int(min(remaining, Int64(1 << 20)))
        let timer = DispatchWorkItem { [weak self] in
            upload.abort()
            self?.close()
        }
        queue.asyncAfter(deadline: .now() + Self.uploadIdleTimeout, execute: timer)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, isComplete, error in
            timer.cancel()
            guard let self else { return upload.abort() }
            var left = remaining
            if let data, !data.isEmpty {
                do { try upload.write(data) } catch { return self.failUpload(upload, error) }
                left -= Int64(data.count)
            }
            if left <= 0 { return self.finishUpload(upload) }
            if error != nil || isComplete {
                upload.abort()
                return self.close()
            }
            self.receiveBody(upload, remaining: left)
        }
    }

    private func finishUpload(_ upload: HubBlobStore.Upload) {
        // Hashing a resumed upload reads the whole file: off the shared connection queue.
        DispatchQueue.global(qos: .userInitiated).async {
            let reply: Data
            do {
                reply = Self.resultBody(try upload.finish().json)
            } catch let failure as HubBlobStore.Failure {
                reply = Self.errorBody(failure.message, code: failure.code)
            } catch {
                reply = Self.errorBody(error.localizedDescription, code: "unavailable")
            }
            self.queue.async { self.respond(status: 200, json: reply) }
        }
    }

    private func failUpload(_ upload: HubBlobStore.Upload, _ error: Error) {
        upload.abort()
        let failure = error as? HubBlobStore.Failure ?? .io(error.localizedDescription)
        respond(status: 200, json: Self.errorBody(failure.message, code: failure.code), drain: true)
    }

    /// After an early reply: close our side, then read and drop what the client is still
    /// sending for up to 2 s, so closing doesn't reset the connection before it reads the reply.
    private func drainThenClose() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        let deadline = DispatchWorkItem { [weak self] in self?.close() }
        queue.asyncAfter(deadline: .now() + 2, execute: deadline)
        func drain() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] _, _, isComplete, error in
                guard let self else { return }
                if isComplete || error != nil {
                    deadline.cancel()
                    return self.close()
                }
                drain()
            }
        }
        drain()
    }

    private func serveBlob(_ sha: String, range: String?) {
        guard let (url, size) = HubBlobStore.shared.resolve(sha) else {
            return respond(status: 404, json: Self.errorBody("No blob \(sha) here", code: "not_found"))
        }
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let range {
            guard let parsed = Self.parseRange(range, size: size) else {
                return respond(status: 416, json: Self.errorBody("Range \(range) does not fit a blob of \(size) bytes; use one bytes=a-b or bytes=a-", code: "invalid_params"))
            }
            (start, end) = parsed
            partial = true
        }
        let accessing = url.startAccessingSecurityScopedResource()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return respond(status: 404, json: Self.errorBody("Blob \(sha) can't be read any more", code: "not_found"))
        }
        let length = size == 0 ? 0 : end - start + 1
        do { try handle.seek(toOffset: UInt64(start)) } catch {
            try? handle.close()
            if accessing { url.stopAccessingSecurityScopedResource() }
            return respond(status: 404, json: Self.errorBody("Blob \(sha) can't be read any more", code: "not_found"))
        }
        var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nHub-Blob-Size: \(size)\r\nAccept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "Connection: close\r\n\r\n"
        let finish = { [weak self] in
            try? handle.close()
            if accessing { url.stopAccessingSecurityScopedResource() }
            self?.close()
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return finish() }
            self.pump(handle, remaining: length, finish: finish)
        })
    }

    /// Sends the next chunk once the previous one is handed to the network: one chunk in
    /// memory at a time however big the file.
    private func pump(_ handle: FileHandle, remaining: Int64, finish: @escaping () -> Void) {
        guard remaining > 0 else { return finish() }
        let data: Data? = autoreleasepool {
            try? handle.read(upToCount: Int(min(remaining, Int64(HubBlobStore.ioChunk))))
        }
        guard let data, !data.isEmpty else { return finish() }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return finish() }
            self.pump(handle, remaining: remaining - Int64(data.count), finish: finish)
        })
    }

    /// One range, `bytes=a-b`, `bytes=a-` or `bytes=-n`, clamped to the blob.
    private static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = value.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int64(last), count > 0 else { return nil }
            return (max(0, size - count), size - 1)
        }
        guard let start = Int64(first), start >= 0, start < size else { return nil }
        if last.isEmpty { return (start, size - 1) }
        guard let end = Int64(last), end >= start else { return nil }
        return (start, min(end, size - 1))
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
