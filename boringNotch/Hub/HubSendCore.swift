//
//  HubSendCore.swift
//  boringNotch
//
//  Send from the notch (hub D-178): the shelf's share surfaces send to the hub devices
//  through the helper. This file is the part without AppKit, so Hub/tests/send-tests.sh
//  can run it against a fake helper: the device list from `peer.list`, the default device,
//  a batch of files and texts, its status line, and the runner that starts
//  `transfer.send` per file and polls `transfer.sends` until every send is finished.
//

import Foundation

// MARK: - Devices

struct HubSendDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let os: String
    let online: Bool

    /// The brand icon in HubIcons.xcassets.
    var iconName: String {
        if kind == "tower" && os == "windows" { return "hub.windows" }
        switch kind {
        case "phone", "tower", "server", "mac": return "hub.\(kind)"
        default: return "hub.hub"
        }
    }
}

enum HubSendTargets {
    /// Kinds that take files on their shelf. The server joins when it accepts files.
    static let fileKinds: [String] = ["phone", "tower"]

    /// `peer.list`'s result -> every device, in its order.
    static func parse(peerList data: Data) -> [HubSendDevice] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty else { return nil }
            return HubSendDevice(id: id,
                                 name: d["name"] as? String ?? id,
                                 kind: d["kind"] as? String ?? "",
                                 os: d["os"] as? String ?? "",
                                 online: d["online"] as? Bool ?? false)
        }
    }

    /// The devices Settings lists: everything that can take files, online or not.
    static func known(_ all: [HubSendDevice]) -> [HubSendDevice] {
        all.filter { fileKinds.contains($0.kind) }
    }

    /// The share targets: online devices that take files, in `peer.list` order.
    static func targets(_ all: [HubSendDevice]) -> [HubSendDevice] {
        known(all).filter(\.online)
    }

    /// The last-used device when it is a target, else the first target.
    static func defaultDevice(targets: [HubSendDevice], lastUsed: String) -> HubSendDevice? {
        targets.first { $0.id == lastUsed } ?? targets.first
    }

    /// What the UI calls a device: "phone" or "tower" when it is the only one of its kind,
    /// else its own name.
    static func label(for device: HubSendDevice, among all: [HubSendDevice]) -> String {
        let sameKind = all.filter { $0.kind == device.kind }.count
        if sameKind <= 1, ["phone", "tower", "server"].contains(device.kind) { return device.kind }
        return device.name
    }
}

// MARK: - Formatting

enum HubSendFormat {
    /// "1.2 of 5.4 GB": both numbers in the total's unit (decimal, like Finder).
    static func progress(_ done: Int64, of total: Int64) -> String {
        let (unit, div, decimals) = scale(for: total)
        return "\(number(Double(min(done, total)) / div, decimals)) of \(number(Double(total) / div, decimals)) \(unit)"
    }

    static func size(_ bytes: Int64) -> String {
        let (unit, div, decimals) = scale(for: bytes)
        return "\(number(Double(bytes) / div, decimals)) \(unit)"
    }

    /// "40 s", "3 min", "1 h 5 min".
    static func remaining(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded(.up)))
        if s < 60 { return "\(s) s" }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private static func scale(for total: Int64) -> (String, Double, Int) {
        let t = Double(total)
        if t >= 1e9 { return ("GB", 1e9, 1) }
        if t >= 1e6 { return ("MB", 1e6, t >= 1e7 ? 0 : 1) }
        if t >= 1e3 { return ("KB", 1e3, 0) }
        return ("bytes", 1, 0)
    }

    private static func number(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

// MARK: - Calls

/// A failed call to the helper, as the send code needs it.
struct HubSendCallError: Error, Equatable {
    enum Kind: Equatable {
        /// No token file or nothing on the port.
        case helperDown
        /// ok:false with this code.
        case rpc(String?)
    }

    var kind: Kind
    var message: String

    /// The helper predates `transfer.send` (D-176).
    var helperOutdated: Bool {
        if case .rpc(let code) = kind { return code == "unknown_method" }
        return false
    }
}

/// One call to the helper's /rpc: op + args -> the result object as JSON. Throws
/// `HubSendCallError` (anything else counts as helper down).
typealias HubSendCall = @Sendable (_ op: String, _ args: [String: Any]) async throws -> Data

// MARK: - Batch

/// What one entry of a batch carries.
enum HubSendPayload: Equatable, Sendable {
    /// A regular file the helper can read (staged by the app), with its size.
    case file(path: String, size: Int64)
    case text(String)
    case link(String)
}

enum HubSendEntryState: Equatable, Sendable {
    case waiting
    case hashing(hashed: Int64)
    case sending(sent: Int64)
    case completed(alreadyPresent: Bool)
    case failed(String)
    case cancelled

    var finished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

struct HubSendEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var payload: HubSendPayload
    /// The shelf item this came from, for the ring on its tile.
    var shelfItemID: UUID?
    var sendID: String?
    var state: HubSendEntryState = .waiting

    init(id: UUID = UUID(), name: String, payload: HubSendPayload, shelfItemID: UUID? = nil) {
        self.id = id
        self.name = name
        self.payload = payload
        self.shelfItemID = shelfItemID
    }

    var size: Int64 {
        if case .file(_, let size) = payload { return size }
        return 0
    }

    var sentBytes: Int64 {
        switch state {
        case .sending(let sent): return sent
        case .completed: return size
        default: return 0
        }
    }

    /// 0...1 for the ring on the tile.
    var fraction: Double {
        guard size > 0 else { return state.finished ? 1 : 0 }
        switch state {
        case .hashing(let hashed): return 0.1 * Double(hashed) / Double(size)
        case .sending(let sent): return 0.1 + 0.9 * Double(sent) / Double(size)
        case .completed: return 1
        default: return 0
        }
    }
}

struct HubSendBatch: Equatable, Identifiable, Sendable {
    let id: UUID
    let deviceID: String
    /// "phone", "tower" or the device's name.
    let deviceLabel: String
    var entries: [HubSendEntry]
    /// Set when the helper has no transfer.send: the owner has to update it.
    var helperOutdated = false
    /// Bytes per second over the last seconds, for the time left.
    var rate: Double = 0

    init(id: UUID = UUID(), deviceID: String, deviceLabel: String, entries: [HubSendEntry]) {
        self.id = id
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.entries = entries
    }

    var finished: Bool { entries.allSatisfy { $0.state.finished } }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    var sentBytes: Int64 { entries.reduce(0) { $0 + $1.sentBytes } }
    var failed: [HubSendEntry] { entries.filter { if case .failed = $0.state { return true } else { return false } } }
    var canRetry: Bool { finished && !failed.isEmpty }

    /// 0...1 for the ring on the drop zone.
    var fraction: Double {
        let total = totalBytes
        if total == 0 {
            return entries.isEmpty ? 0 : Double(entries.filter { $0.state.finished }.count) / Double(entries.count)
        }
        return entries.reduce(0.0) { $0 + $1.fraction * Double($1.size) } / Double(total)
    }

    /// The line under the ring: "Sending to phone · 1.2 of 5.4 GB · 3 min", then the result.
    var statusLine: String {
        if helperOutdated { return "Update the hub helper" }
        if !finished {
            let hashing = entries.filter { if case .hashing = $0.state { return true } else { return false } }
            if sentBytes == 0, !hashing.isEmpty {
                let hashed = entries.reduce(Int64(0)) { sum, e in
                    switch e.state {
                    case .hashing(let h): return sum + h
                    case .sending, .completed: return sum + e.size
                    default: return sum
                    }
                }
                return "Preparing for \(deviceLabel) · \(HubSendFormat.progress(hashed, of: totalBytes))"
            }
            guard totalBytes > 0 else { return "Sending to \(deviceLabel)" }
            var line = "Sending to \(deviceLabel) · \(HubSendFormat.progress(sentBytes, of: totalBytes))"
            if rate > 0 {
                line += " · \(HubSendFormat.remaining(Double(totalBytes - sentBytes) / rate))"
            }
            return line
        }
        if let first = failed.first, case .failed(let why) = first.state {
            return "Didn't arrive: \(why)"
        }
        if entries.contains(where: { $0.state == .cancelled }) { return "Cancelled" }
        if !entries.isEmpty, entries.allSatisfy({ $0.state == .completed(alreadyPresent: true) }) {
            return "Already on \(deviceLabel)"
        }
        return "On \(deviceLabel)"
    }

    /// The line in two parts for the small drop zone: "Sending to phone" and
    /// "1.2 of 5.4 GB · 3 min"; "Didn't arrive" and why.
    var statusParts: (title: String, detail: String?) {
        let line = statusLine
        if line.hasPrefix("Didn't arrive: ") {
            return ("Didn't arrive", String(line.dropFirst("Didn't arrive: ".count)))
        }
        guard let r = line.range(of: " · ") else { return (line, nil) }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }

    /// The failed entries again, as a fresh batch (Retry).
    func retryBatch() -> HubSendBatch {
        var again = HubSendBatch(deviceID: deviceID, deviceLabel: deviceLabel, entries: failed.map {
            HubSendEntry(id: $0.id, name: $0.name, payload: $0.payload, shelfItemID: $0.shelfItemID)
        })
        again.helperOutdated = false
        return again
    }
}

// MARK: - Runner

/// Runs one batch: `transfer.send` per file, `peer.call shelf.put` per text or link, then
/// `transfer.sends` every `pollInterval` until every send is finished. Cancel with
/// `cancel(_:)` from anywhere; the next poll sees the sends cancelled.
final class HubSendRunner: @unchecked Sendable {
    let call: HubSendCall
    let pollInterval: Duration
    /// Polls without an answer before the batch is given up (the helper went away).
    let maxFailedPolls: Int

    init(call: @escaping HubSendCall, pollInterval: Duration = .milliseconds(500), maxFailedPolls: Int = 20) {
        self.call = call
        self.pollInterval = pollInterval
        self.maxFailedPolls = maxFailedPolls
    }

    func run(_ start: HubSendBatch, update: @escaping @Sendable (HubSendBatch) async -> Void) async -> HubSendBatch {
        var batch = start

        for i in batch.entries.indices where !batch.entries[i].state.finished {
            let entry = batch.entries[i]
            switch entry.payload {
            case .file(let path, _):
                if batch.helperOutdated {
                    batch.entries[i].state = .failed("the hub helper is too old to send files")
                    continue
                }
                do {
                    let data = try await call("transfer.send", ["device": batch.deviceID, "path": path, "name": entry.name])
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    if let id = object?["send_id"] as? String, !id.isEmpty {
                        batch.entries[i].sendID = id
                        batch.entries[i].state = .hashing(hashed: 0)
                    } else {
                        batch.entries[i].state = .failed("the hub helper sent no send id")
                    }
                } catch {
                    let e = Self.classify(error)
                    if e.helperOutdated { batch.helperOutdated = true }
                    batch.entries[i].state = .failed(Self.reason(e))
                }
            case .text(let text):
                batch.entries[i].state = await put(["text": text], to: batch.deviceID)
            case .link(let url):
                batch.entries[i].state = await put(["url": url], to: batch.deviceID)
            }
            await update(batch)
        }

        var samples: [(Date, Int64)] = []
        var failedPolls = 0
        while !batch.finished {
            try? await Task.sleep(for: pollInterval)
            do {
                let data = try await call("transfer.sends", [:])
                failedPolls = 0
                apply(sends: data, to: &batch)
            } catch {
                failedPolls += 1
                if failedPolls >= maxFailedPolls {
                    let why = Self.reason(Self.classify(error))
                    for i in batch.entries.indices where !batch.entries[i].state.finished {
                        batch.entries[i].state = .failed(why)
                    }
                }
            }
            let now = Date()
            samples.append((now, batch.sentBytes))
            samples.removeAll { now.timeIntervalSince($0.0) > 10 }
            if let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) >= 1 {
                batch.rate = max(0, Double(last.1 - first.1) / last.0.timeIntervalSince(first.0))
            }
            await update(batch)
        }
        await update(batch)
        return batch
    }

    /// Cancels every running send of the batch.
    func cancel(_ batch: HubSendBatch) async {
        for entry in batch.entries where !entry.state.finished {
            guard let id = entry.sendID else { continue }
            _ = try? await call("transfer.sends", ["send_id": id, "cancel": true])
        }
    }

    /// Folds a `transfer.sends` result into the batch.
    func apply(sends data: Data, to batch: inout HubSendBatch) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sends = object["sends"] as? [[String: Any]]
        else { return }
        var byID: [String: [String: Any]] = [:]
        for s in sends { if let id = s["send_id"] as? String { byID[id] = s } }
        for i in batch.entries.indices where !batch.entries[i].state.finished {
            guard let id = batch.entries[i].sendID else { continue }
            guard let s = byID[id] else {
                // Gone from the list: the helper restarted and forgot it.
                batch.entries[i].state = .failed("the hub helper restarted")
                continue
            }
            batch.entries[i].state = Self.state(of: s, size: batch.entries[i].size)
        }
    }

    static func state(of s: [String: Any], size: Int64) -> HubSendEntryState {
        let sent = int64(s["sent_bytes"])
        switch s["state"] as? String {
        case "hashing": return .hashing(hashed: int64(s["hashed_bytes"]))
        case "sending", "retrying": return .sending(sent: sent)
        case "completed":
            let item = s["item"] as? [String: Any]
            return .completed(alreadyPresent: item?["already_present"] as? Bool ?? false)
        case "failed": return .failed(nonEmpty(s["error"] as? String) ?? "the transfer failed")
        case "cancelled": return .cancelled
        default: return .sending(sent: sent)
        }
    }

    private func put(_ params: [String: Any], to device: String) async -> HubSendEntryState {
        do {
            let data = try await call("peer.call", ["device": device, "method": "shelf.put", "params": params, "timeout_ms": 10_000])
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let result = object?["result"] as? [String: Any]
            return .completed(alreadyPresent: result?["already_present"] as? Bool ?? false)
        } catch {
            return .failed(Self.reason(Self.classify(error)))
        }
    }

    static func classify(_ error: Error) -> HubSendCallError {
        (error as? HubSendCallError) ?? HubSendCallError(kind: .helperDown, message: error.localizedDescription)
    }

    /// The "why" after "Didn't arrive:".
    static func reason(_ e: HubSendCallError) -> String {
        switch e.kind {
        case .helperDown: return "the hub helper isn't running"
        case .rpc(let code) where code == "unknown_method": return "the hub helper is too old to send files"
        case .rpc:
            let m = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "the transfer failed" : m
        }
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
