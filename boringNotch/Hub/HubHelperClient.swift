//
//  HubHelperClient.swift
//  boringNotch
//
//  Calls the embedded hub helper (towerbridge, hub D-128) on its loopback /rpc, the
//  other way round from the usual direction (the helper calls this app's bridge). The
//  helper shares its token at ~/.config/boringnotch/hub/<label>.json
//  (`HubHelper.shareTokenURL`); the envelope is the hub contract's {op, args} ->
//  {ok, result | error, code}. The helper reaches other devices with `peer.call`,
//  sealed end to end, so this app stays loopback-only.
//

import Foundation

enum HubHelperClient {
    struct Failure: Error, Equatable {
        enum Kind: Equatable {
            /// This build carries no helper.
            case noHelper
            /// No token file, or nothing answers on its port: the helper isn't running.
            case helperDown
            /// The helper (or, through peer.call, the other device) answered ok:false.
            case rpc(code: String?)
        }

        var kind: Kind
        var message: String

        var code: String? {
            if case .rpc(let code) = kind { return code }
            return nil
        }
    }

    private struct TokenFile: Decodable {
        let port: Int
        let token: String
        let pid: Int32?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // loopback; never through a proxy
        return URLSession(configuration: config)
    }()

    /// One call; returns the `result` object as JSON.
    static func call(_ op: String, args: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> Data {
        guard let tokenURL = HubHelper.shareTokenURL else {
            throw Failure(kind: .noHelper, message: "This build has no hub helper")
        }
        guard let data = try? Data(contentsOf: tokenURL),
              let token = try? JSONDecoder().decode(TokenFile.self, from: data),
              (1...65535).contains(token.port), !token.token.isEmpty
        else {
            throw Failure(kind: .helperDown, message: "The hub helper isn't running (no \(tokenURL.lastPathComponent))")
        }
        if let pid = token.pid, kill(pid, 0) != 0, errno == ESRCH {
            throw Failure(kind: .helperDown, message: "The hub helper isn't running (stale token file)")
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(token.port)/rpc")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["op": op, "args": args])

        let body: Data
        do {
            (body, _) = try await session.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
            throw Failure(kind: .helperDown, message: "The hub helper isn't answering")
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Failure(kind: .rpc(code: "internal"), message: "The hub helper sent something unreadable")
        }
        guard object["ok"] as? Bool == true else {
            throw Failure(kind: .rpc(code: object["code"] as? String),
                          message: object["error"] as? String ?? "The hub helper refused the call")
        }
        return try JSONSerialization.data(withJSONObject: object["result"] ?? [String: Any](), options: [.fragmentsAllowed])
    }

    /// `peer.call`: `method` on another device, through the helper. Returns that method's result.
    static func peerCall(device: String, method: String, params: [String: Any] = [:],
                         timeoutMs: Int = 10_000) async throws -> Data {
        let data = try await call("peer.call", args: [
            "device": device, "method": method, "params": params, "timeout_ms": timeoutMs,
        ], timeout: Double(timeoutMs) / 1000 + 5)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(kind: .rpc(code: "internal"), message: "peer.call sent something unreadable")
        }
        return try JSONSerialization.data(withJSONObject: object["result"] ?? [String: Any](), options: [.fragmentsAllowed])
    }
}
