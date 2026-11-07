// Tests for boringNotch/Hub/HubSendCore.swift (hub send, D-178) against a fake helper.
// Run with Hub/tests/send-tests.sh (macOS: swiftc; Linux: the swift Docker image).

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

// MARK: fake helper

/// Answers transfer.send / transfer.sends / peer.call like towerbridge (D-176): every poll
/// moves a send along hashing -> sending (in `steps`) -> completed, unless told otherwise.
final class FakeHelper: @unchecked Sendable {
    struct Send {
        var device: String, name: String, size: Int64
        var state = "hashing", hashed: Int64 = 0, sent: Int64 = 0
        var error: String?, alreadyPresent = false
    }

    let lock = NSLock()
    var sends: [String: Send] = [:]
    var order: [String] = []
    var calls: [(String, [String: Any])] = []
    var outdated = false
    var down = false
    var failName: String?
    var presentNames: Set<String> = []
    var steps: Int64 = 4
    var putResult: [String: Any] = ["id": "x", "name": "Text", "already_present": false]

    func call(_ op: String, _ args: [String: Any]) async throws -> Data {
        try lock.withLock { try handle(op, args) }
    }

    private func handle(_ op: String, _ args: [String: Any]) throws -> Data {
        calls.append((op, args))
        if down { throw HubSendCallError(kind: .helperDown, message: "down") }
        switch op {
        case "transfer.send":
            if outdated { throw HubSendCallError(kind: .rpc("unknown_method"), message: "Unknown op transfer.send") }
            guard let path = args["path"] as? String, path.hasPrefix("/") else {
                throw HubSendCallError(kind: .rpc("invalid_params"), message: "path must be absolute")
            }
            let id = "s\(order.count + 1)"
            let size = Int64(path.split(separator: "-").last.flatMap { Int64($0) } ?? 1000)
            sends[id] = Send(device: args["device"] as? String ?? "", name: args["name"] as? String ?? "", size: size)
            order.append(id)
            return json(["send_id": id])
        case "transfer.sends":
            if let id = args["send_id"] as? String, args["cancel"] as? Bool == true {
                if var s = sends[id], !["completed", "failed", "cancelled"].contains(s.state) {
                    s.state = "cancelled"; sends[id] = s
                }
                return json(["sends": []])
            }
            var out: [[String: Any]] = []
            for id in order {
                guard var s = sends[id] else { continue }
                switch s.state {
                case "hashing":
                    s.hashed = min(s.size, s.hashed + s.size / 2)
                    if s.hashed >= s.size { s.state = "sending" }
                case "sending":
                    if s.name == failName { s.state = "failed"; s.error = "phone is offline" }
                    else {
                        s.sent = min(s.size, s.sent + s.size / steps)
                        if s.sent >= s.size { s.state = "completed"; s.alreadyPresent = presentNames.contains(s.name) }
                    }
                default: break
                }
                sends[id] = s
                var info: [String: Any] = ["send_id": id, "device": s.device, "name": s.name, "size": s.size,
                                           "sent_bytes": s.sent, "hashed_bytes": s.hashed, "state": s.state,
                                           "started": "2026-11-07T00:00:00Z", "updated": "2026-11-07T00:00:00Z"]
                if let e = s.error { info["error"] = e; info["code"] = "unavailable" }
                if s.state == "completed" { info["item"] = ["id": "i", "name": s.name, "already_present": s.alreadyPresent] }
                out.append(info)
            }
            return json(["sends": out])
        case "peer.call":
            return json(["result": putResult])
        default:
            throw HubSendCallError(kind: .rpc("unknown_method"), message: "Unknown op \(op)")
        }
    }

    func ops() -> [String] { lock.withLock { calls.map(\.0) } }
}

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var updates: [HubSendBatch] = []
    func add(_ b: HubSendBatch) { lock.withLock { updates.append(b) } }
    var lines: [String] { lock.withLock { updates.map(\.statusLine) } }
}

func runner(_ fake: FakeHelper) -> HubSendRunner {
    HubSendRunner(call: { op, args in try await fake.call(op, args) }, pollInterval: .milliseconds(5), maxFailedPolls: 3)
}

func file(_ name: String, _ size: Int64) -> HubSendEntry {
    HubSendEntry(name: name, payload: .file(path: "/tmp/outbox/x/\(name)-\(size)", size: size))
}

let sem = DispatchSemaphore(value: 0)
Task {
    // MARK: devices
    do {
        let list = json(["devices": [
            ["id": "mac", "name": "MacBook Air", "kind": "mac", "os": "macos", "public_key": "k", "online": true],
            ["id": "phone", "name": "Leó S23", "kind": "phone", "os": "android", "public_key": "k", "online": true],
            ["id": "server", "name": "Server", "kind": "server", "os": "linux", "public_key": "k", "online": true],
            ["id": "tower", "name": "Tower", "kind": "tower", "os": "omarchy", "public_key": "k", "online": false],
            ["id": "tablet", "name": "Tab", "kind": "phone", "os": "android", "public_key": "k", "online": true],
        ]])
        let all = HubSendTargets.parse(peerList: list)
        check(all.count == 5, "parse all")
        let targets = HubSendTargets.targets(all)
        check(targets.map(\.id) == ["phone", "tablet"], "online file-taking devices in order, no mac/server/offline: \(targets.map(\.id))")
        check(HubSendTargets.known(all).map(\.id) == ["phone", "tower", "tablet"], "settings list keeps offline")
        check(HubSendTargets.defaultDevice(targets: targets, lastUsed: "tablet")?.id == "tablet", "last used is default")
        check(HubSendTargets.defaultDevice(targets: targets, lastUsed: "tower")?.id == "phone", "offline last used -> first")
        check(HubSendTargets.defaultDevice(targets: targets, lastUsed: "")?.id == "phone", "none -> first")
        check(HubSendTargets.defaultDevice(targets: [], lastUsed: "phone") == nil, "no targets")
        check(HubSendTargets.label(for: all[3], among: all) == "tower", "unique kind -> kind word")
        check(HubSendTargets.label(for: all[1], among: all) == "Leó S23", "two phones -> name")
        check(HubSendDevice(id: "t", name: "T", kind: "tower", os: "windows", online: true).iconName == "hub.windows", "windows icon")
        check(all[1].iconName == "hub.phone", "phone icon")
        check(HubSendTargets.parse(peerList: Data("nope".utf8)).isEmpty, "garbage -> empty")
    }

    // MARK: formatting
    check(HubSendFormat.progress(1_200_000_000, of: 5_400_000_000) == "1.2 of 5.4 GB", "GB progress")
    check(HubSendFormat.progress(12_000_000, of: 54_000_000) == "12 of 54 MB", "MB progress")
    check(HubSendFormat.progress(300_000, of: 900_000) == "300 of 900 KB", "KB progress")
    check(HubSendFormat.remaining(40) == "40 s", "seconds")
    check(HubSendFormat.remaining(170) == "3 min", "minutes")
    check(HubSendFormat.remaining(3900) == "1 h 5 min", "hours")

    // MARK: status line
    do {
        var b = HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("a", 5_400_000_000)])
        b.entries[0].state = .hashing(hashed: 1_200_000_000)
        check(b.statusLine == "Preparing for phone · 1.2 of 5.4 GB", "hashing line: \(b.statusLine)")
        b.entries[0].state = .sending(sent: 1_200_000_000)
        b.rate = 23_333_333
        check(b.statusLine == "Sending to phone · 1.2 of 5.4 GB · 3 min", "sending line: \(b.statusLine)")
        check(b.statusParts.title == "Sending to phone" && b.statusParts.detail == "1.2 of 5.4 GB · 3 min", "parts")
        b.entries[0].state = .completed(alreadyPresent: false)
        check(b.statusLine == "On phone", "done")
        b.entries[0].state = .completed(alreadyPresent: true)
        check(b.statusLine == "Already on phone", "already")
        b.entries[0].state = .failed("phone is offline")
        check(b.statusLine == "Didn't arrive: phone is offline", "failed")
        check(b.statusParts.title == "Didn't arrive" && b.statusParts.detail == "phone is offline", "failed parts")
        check(b.canRetry, "retry offered")
        let again = b.retryBatch()
        check(again.entries.count == 1 && again.entries[0].state == .waiting && again.id != b.id, "retry batch")
        b.helperOutdated = true
        check(b.statusLine == "Update the hub helper", "outdated")
    }

    // MARK: runner: two files complete, progress seen, ids carried
    do {
        let fake = FakeHelper()
        fake.presentNames = ["b"]
        let rec = Recorder()
        let start = HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("a", 4000), file("b", 2000)])
        let done = await runner(fake).run(start) { rec.add($0) }
        check(done.finished, "finished")
        check(done.entries.map(\.state) == [.completed(alreadyPresent: false), .completed(alreadyPresent: true)], "states \(done.entries.map(\.state))")
        check(done.statusLine == "On phone", "line \(done.statusLine)")
        check(rec.lines.contains { $0.hasPrefix("Preparing for phone") }, "hashing seen")
        check(rec.lines.contains { $0.hasPrefix("Sending to phone · ") }, "sending seen \(rec.lines)")
        let sendCalls = fake.calls.filter { $0.0 == "transfer.send" }
        check(sendCalls.count == 2 && sendCalls[0].1["device"] as? String == "phone" && sendCalls[0].1["name"] as? String == "a", "transfer.send args")
        check(done.entries[0].sendID == "s1", "send id kept")
    }

    // MARK: all already present
    do {
        let fake = FakeHelper()
        fake.presentNames = ["a"]
        let done = await runner(fake).run(HubSendBatch(deviceID: "tower", deviceLabel: "tower", entries: [file("a", 100)])) { _ in }
        check(done.statusLine == "Already on tower", "already on tower: \(done.statusLine)")
    }

    // MARK: failure and retry
    do {
        let fake = FakeHelper()
        fake.failName = "a"
        let r = runner(fake)
        let done = await r.run(HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("a", 1000), file("b", 1000)])) { _ in }
        check(done.statusLine == "Didn't arrive: phone is offline", "failed line \(done.statusLine)")
        check(done.failed.count == 1, "one failed")
        fake.failName = nil
        let again = await r.run(done.retryBatch()) { _ in }
        check(again.statusLine == "On phone" && again.entries.count == 1, "retry ok: \(again.statusLine)")
    }

    // MARK: cancel
    do {
        let fake = FakeHelper()
        fake.steps = 1_000_000
        let r = runner(fake)
        let rec = Recorder()
        let task = Task { await r.run(HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("big", 5_000_000_000)])) { rec.add($0) } }
        // Wait for it to be sending, then cancel.
        for _ in 0..<200 {
            if let last = rec.updates.last, case .sending = last.entries[0].state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let last = rec.updates.last { await r.cancel(last) }
        let done = await task.value
        check(done.entries[0].state == .cancelled && done.statusLine == "Cancelled", "cancelled: \(done.statusLine)")
        check(fake.calls.contains { $0.0 == "transfer.sends" && $0.1["cancel"] as? Bool == true && $0.1["send_id"] as? String == "s1" }, "cancel call sent")
    }

    // MARK: outdated helper -> "Update the hub helper", texts still go
    do {
        let fake = FakeHelper()
        fake.outdated = true
        let entries = [file("a", 10), file("b", 10), HubSendEntry(name: "Text", payload: .text("hello"))]
        let done = await runner(fake).run(HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: entries)) { _ in }
        check(done.helperOutdated && done.statusLine == "Update the hub helper", "outdated line \(done.statusLine)")
        check(fake.ops().filter { $0 == "transfer.send" }.count == 1, "stops asking after unknown_method")
        check(done.entries[2].state == .completed(alreadyPresent: false), "text still sent")
    }

    // MARK: text and links through peer.call shelf.put
    do {
        let fake = FakeHelper()
        fake.putResult = ["id": "x", "name": "x", "already_present": true]
        let entries = [HubSendEntry(name: "Text", payload: .text("hi")), HubSendEntry(name: "l", payload: .link("https://example.com"))]
        let done = await runner(fake).run(HubSendBatch(deviceID: "tower", deviceLabel: "tower", entries: entries)) { _ in }
        check(done.statusLine == "Already on tower", "text already: \(done.statusLine)")
        let puts = fake.calls.filter { $0.0 == "peer.call" }
        check(puts.count == 2 && puts[0].1["method"] as? String == "shelf.put" && puts[0].1["device"] as? String == "tower", "peer.call shelf.put")
        check((puts[0].1["params"] as? [String: Any])?["text"] as? String == "hi", "text param")
        check((puts[1].1["params"] as? [String: Any])?["url"] as? String == "https://example.com", "url param")
        check(!fake.ops().contains("transfer.sends"), "no polling for texts only")
    }

    // MARK: helper goes away mid-send
    do {
        let fake = FakeHelper()
        fake.steps = 1_000_000
        let r = runner(fake)
        let task = Task { await r.run(HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("a", 1_000_000)])) { _ in } }
        try? await Task.sleep(for: .milliseconds(30))
        fake.lock.withLock { fake.down = true }
        let done = await task.value
        check(done.statusLine == "Didn't arrive: the hub helper isn't running", "helper down: \(done.statusLine)")
    }

    // MARK: send forgotten by a restarted helper
    do {
        let r = runner(FakeHelper())
        var b = HubSendBatch(deviceID: "phone", deviceLabel: "phone", entries: [file("a", 10)])
        b.entries[0].sendID = "gone"
        b.entries[0].state = .sending(sent: 1)
        r.apply(sends: json(["sends": []]), to: &b)
        check(b.entries[0].state == .failed("the hub helper restarted"), "forgotten send")
    }

    sem.signal()
}
sem.wait()

if failures == 0 {
    print("send tests: all passed")
} else {
    print("send tests: \(failures) failed")
    exit(1)
}
