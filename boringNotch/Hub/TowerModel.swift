//
//  TowerModel.swift
//  boringNotch
//
//  Remote wake (hub D-145): the tower's power state and the progress of a boot, as the
//  hub's server node reports them. The server owns the work (the ESP32 wake relay at
//  home sends the magic packet, the pre-boot SSH unlocks the disk or picks Windows for
//  one boot); this app only asks, through the hub helper's sealed `peer.call`:
//
//    power.boot {os}  -> {accepted, state, eta_seconds}   returns at once
//    power.state {}   -> {state, phase, detail, error, eta_seconds, relay{online…}, …}
//
//  Polling: every 1.5 s while a boot runs (whether or not the notch is open, so the
//  closed-notch peek can say when it's done), otherwise every 6 s while the Tower tab is
//  on screen, and not at all when nobody looks.
//

import Defaults
import Foundation
import SwiftUI

@MainActor
final class TowerModel: ObservableObject {
    static let shared = TowerModel()

    /// The hub device id of the server node, which runs the wake (D-145).
    static let serverDevice = "server"

    /// Why there is no tower state to show.
    enum Problem: Equatable {
        /// The server answered, but its power module isn't there or isn't on yet.
        case notSetUp
        /// This build has no helper, or the helper isn't running.
        case noHelper(String)
        /// The helper runs but isn't paired with a hub.
        case notPaired
        /// The hub or the server didn't answer.
        case unreachable(String)
    }

    @Published private(set) var power: HubRPC.PowerStateResult?
    @Published private(set) var problem: Problem?
    /// The boot this Mac asked for, from the tap until the server's state shows it.
    @Published private(set) var requested: HubRPC.PowerBootParamsOS?
    /// power.boot itself failed (refused, or never reached the server).
    @Published private(set) var requestError: String?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var loading = false
    /// Phases seen during the current boot, to tell a cold boot from a switch.
    @Published private(set) var seenSwitching = false

    private var viewers = 0
    private var pollTask: Task<Void, Never>?
    private var lastPhase: HubRPC.PowerStateResultPhase?

    private init() {}

    /// Whether the Tower tab exists: this build has the helper, and the user wants it.
    static var tabEnabled: Bool { HubHelper.isEmbedded && Defaults[.showTowerTab] }

    var isBooting: Bool {
        if requested != nil { return true }
        guard let phase = power?.phase else { return false }
        return Self.runningPhases.contains(phase)
    }

    static let runningPhases: Set<HubRPC.PowerStateResultPhase> = [.waking, .unlocking, .starting, .switching]

    // MARK: - Viewing

    func appeared() {
        viewers += 1
        refreshSoon()
    }

    func disappeared() {
        viewers = max(0, viewers - 1)
    }

    func refreshSoon() {
        if pollTask == nil { startPolling() } else { Task { await refresh() } }
    }

    // MARK: - Actions

    func boot(_ os: HubRPC.PowerBootParamsOS) {
        guard !isBooting else { return }
        requested = os
        requestError = nil
        seenSwitching = false
        lastPhase = nil
        Task {
            do {
                let data = try await backend.boot(os)
                let result = try JSONDecoder().decode(HubRPC.PowerBootResult.self, from: data)
                if !result.accepted {
                    requested = nil
                    requestError = "The server didn't take the request"
                }
            } catch {
                requested = nil
                let (problem, message) = Self.classify(error)
                if problem == .notSetUp { self.problem = .notSetUp } else { requestError = message }
            }
            await refresh()
            startPolling()
        }
    }

    func retry() {
        let target: HubRPC.PowerBootParamsOS? = requested
            ?? power?.target.flatMap { HubRPC.PowerBootParamsOS(rawValue: $0.rawValue) }
        requestError = nil
        if let target { boot(target) } else { refreshSoon() }
    }

    func dismissError() {
        requestError = nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval: Double
                if self.isBooting {
                    interval = 1.5
                } else if self.viewers > 0 {
                    interval = 6
                } else {
                    break
                }
                try? await Task.sleep(for: .seconds(interval))
            }
            self?.pollTask = nil
        }
    }

    private func refresh() async {
        loading = power == nil && problem == nil
        defer { loading = false }
        do {
            let data = try await backend.state()
            let state = try JSONDecoder().decode(HubRPC.PowerStateResult.self, from: data)
            apply(state)
        } catch {
            let (problem, _) = Self.classify(error)
            self.problem = problem
            if problem == .notSetUp { requested = nil }
        }
        lastUpdate = Date()
    }

    private func apply(_ state: HubRPC.PowerStateResult) {
        problem = nil
        let previous = lastPhase
        power = state
        lastPhase = state.phase
        if state.phase == .switching { seenSwitching = true }
        // The server took over once it reports a running (or finished) boot for our target.
        if let requested, let phase = state.phase, phase != .idle,
           state.target?.rawValue == requested.rawValue {
            self.requested = nil
        }
        // A boot this app watched just ended: say so in the closed notch.
        if let previous, Self.runningPhases.contains(previous), let phase = state.phase,
           phase == .done || phase == .failed {
            HubActivity.shared.towerFinished(
                title: phase == .done ? "Tower is on \(Self.osName(state.target?.rawValue) ?? Self.stateTitle(state.state))" : "Tower didn't start",
                subtitle: phase == .done ? "Ready" : (state.error ?? state.detail ?? "Open the notch to retry"),
                glyph: phase == .failed ? "hub.error" : (state.target == .windows ? "hub.windows" : "hub.tower"),
                failed: phase == .failed
            )
        }
    }

    // MARK: - Errors

    static func classify(_ error: Error) -> (Problem, String) {
        guard let failure = error as? HubHelperClient.Failure else {
            return (.unreachable("Couldn't read the server's answer"), error.localizedDescription)
        }
        switch failure.kind {
        case .noHelper, .helperDown:
            return (.noHelper(failure.message), failure.message)
        case .rpc(let code):
            let text = failure.message.lowercased()
            if text.contains("not paired") { return (.notPaired, failure.message) }
            // Until the server runs the power module: "unavailable … not implemented yet";
            // an older server says unknown_method or module_disabled.
            if code == "unknown_method" || code == "module_disabled"
                || (code == "unavailable" && text.contains("not implemented")) {
                return (.notSetUp, failure.message)
            }
            return (.unreachable(Self.cleanMessage(failure.message)), failure.message)
        }
    }

    /// peer.call prefixes the other device's errors with "server: "; the UI names the server itself.
    private static func cleanMessage(_ message: String) -> String {
        var m = message
        if m.hasPrefix(serverDevice + ": ") { m.removeFirst(serverDevice.count + 2) }
        guard let first = m.first else { return "No answer" }
        return first.uppercased() + m.dropFirst()
    }

    // MARK: - Words (docs/BRAND.md voice)

    static func osName(_ raw: String?) -> String? {
        switch raw {
        case "omarchy": return "Omarchy"
        case "windows": return "Windows"
        default: return nil
        }
    }

    static func stateTitle(_ state: HubRPC.PowerState) -> String {
        switch state {
        case .off: return "Off"
        case .locked: return "Waiting for the disk unlock"
        case .omarchy: return "On Omarchy"
        case .windows: return "On Windows"
        case .nossh: return "On, not answering"
        case .suspended: return "Asleep"
        case .unknown: return "State unknown"
        }
    }

    // MARK: - Backend

    /// The real server, or a stand-in for agent tests (DEBUG `debug.tower`).
    protocol Backend: Sendable {
        func state() async throws -> Data
        func boot(_ os: HubRPC.PowerBootParamsOS) async throws -> Data
    }

    struct ServerBackend: Backend {
        func state() async throws -> Data {
            try await HubHelperClient.peerCall(device: TowerModel.serverDevice, method: "power.state", timeoutMs: 8000)
        }

        func boot(_ os: HubRPC.PowerBootParamsOS) async throws -> Data {
            try await HubHelperClient.peerCall(device: TowerModel.serverDevice, method: "power.boot",
                                               params: ["os": os.rawValue], timeoutMs: 10_000)
        }
    }

    private var backend: Backend = ServerBackend()

    #if DEBUG
    /// Swaps in a fake server (or back to the real one) and starts over.
    func useBackend(_ backend: Backend?) {
        pollTask?.cancel()
        pollTask = nil
        self.backend = backend ?? ServerBackend()
        power = nil
        problem = nil
        requested = nil
        requestError = nil
        lastPhase = nil
        seenSwitching = false
        refreshSoon()
    }
    #endif
}

#if DEBUG
/// A pretend server for agent tests and screenshots, so nobody powers on real hardware.
/// Scenarios: off, omarchy, windows, locked, relay_offline, not_set_up, failed, booting.
/// A boot runs waking 6 s, unlocking 2 s, starting 6 s (switching 3 s from a running OS),
/// and fails at unlocking when the scenario is `fail_boot`.
actor FakeTowerBackend: TowerModel.Backend {
    private var scenario: String
    private var bootStart: Date?
    private var target = "omarchy"
    private var from = "off"

    init(scenario: String) {
        self.scenario = scenario
        if scenario == "booting" {
            bootStart = Date()
        }
    }

    func state() async throws -> Data {
        let now = Date()
        var out: [String: Any] = [
            "state": "off", "phase": "idle", "since": ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 3600)),
            "relay": ["online": true, "last_seen": ISO8601DateFormatter().string(from: now), "rssi": -58, "version": "0.3.1"],
        ]
        switch scenario {
        case "not_set_up":
            throw HubHelperClient.Failure(kind: .rpc(code: "unavailable"), message: "server: power.state is not implemented yet")
        case "unreachable":
            throw HubHelperClient.Failure(kind: .rpc(code: "unavailable"), message: "server: no answer within 8s")
        case "omarchy", "windows", "locked", "suspended", "nossh":
            out["state"] = scenario
        case "relay_offline":
            out["relay"] = ["online": false, "last_seen": ISO8601DateFormatter().string(from: now.addingTimeInterval(-41 * 60))]
        case "failed":
            out["phase"] = "failed"; out["target"] = "omarchy"
            out["error"] = "The tower didn't answer the magic packet within 60 s"
            out["detail"] = "Waking didn't work"
        default:
            break
        }
        if let start = bootStart {
            let t = now.timeIntervalSince(start)
            out["target"] = target
            out["started"] = ISO8601DateFormatter().string(from: start)
            let steps: [(String, Double, String)] = from == "off"
                ? [("waking", 6, "Waiting for the tower to wake"),
                   ("unlocking", 2, target == "windows" ? "Choosing Windows for this boot" : "Unlocking the disk"),
                   ("starting", 6, target == "windows" ? "Windows is starting" : "Omarchy is starting")]
                : [("switching", 3, "Restarting into \(target == "windows" ? "Windows" : "Omarchy")"),
                   ("starting", 6, target == "windows" ? "Windows is starting" : "Omarchy is starting")]
            var elapsed = 0.0
            var phase = "done"
            for (name, length, detail) in steps {
                if t < elapsed + length {
                    phase = name
                    out["detail"] = detail
                    out["eta_seconds"] = Int((steps.map { $0.1 }.reduce(0, +) - t).rounded(.up))
                    break
                }
                elapsed += length
            }
            if scenario == "fail_boot", t >= 6 {
                phase = "failed"
                out["detail"] = "Unlock didn't work"
                out["error"] = "The pre-boot SSH didn't answer"
                out.removeValue(forKey: "eta_seconds")
            }
            out["phase"] = phase
            out["state"] = phase == "done" ? target : (phase == "starting" ? "nossh" : (phase == "unlocking" ? "locked" : from))
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    func boot(_ os: HubRPC.PowerBootParamsOS) async throws -> Data {
        if scenario == "not_set_up" {
            throw HubHelperClient.Failure(kind: .rpc(code: "unavailable"), message: "server: power.boot is not implemented yet")
        }
        from = ["omarchy", "windows"].contains(scenario) ? scenario : "off"
        if scenario == "failed" { scenario = "off" }
        target = os.rawValue
        bootStart = Date()
        return try JSONSerialization.data(withJSONObject: ["accepted": true, "state": from, "eta_seconds": 14])
    }
}
#endif
