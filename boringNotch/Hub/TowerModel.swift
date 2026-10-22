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
//    power.off {mode} -> {accepted, state}                  (D-146; the server relays it to
//                                                           the tower, which then shuts down)
//
//  Polling: every 1.5 s while a boot or a shutdown runs (whether or not the notch is open, so the
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
    /// Shut down was tapped once: the tab asks "Shut down the tower?" (D-146).
    @Published private(set) var confirmingOff = false
    /// The shutdown (or restart) this Mac asked for, from the tap until the tower is off
    /// (or back, for a restart) or the wait runs out.
    @Published private(set) var stopping: HubRPC.PowerOffParamsMode?
    /// power.off failed (refused, or never reached the server), or the tower stayed on.
    @Published private(set) var offError: String?

    /// How long to wait for the tower to go off (a restart also has to come back).
    static var offTimeout: TimeInterval = 60
    static var rebootTimeout: TimeInterval = 180

    private var stopStarted: Date?
    /// A restart has to leave the running OS before "back on" counts.
    private var sawDown = false
    private var confirmTask: Task<Void, Never>?

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
        offError = nil
    }

    /// Whether Shut down is offered: only while an OS runs and nothing else is going on.
    var canShutDown: Bool {
        guard let state = power?.state, state == .omarchy || state == .windows else { return false }
        return !isBooting && stopping == nil
    }

    /// First tap on Shut down: ask before doing it. The question goes away on its own.
    func askToShutDown() {
        guard canShutDown else { return }
        offError = nil
        confirmingOff = true
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.confirmingOff = false
        }
    }

    func cancelShutDown() {
        confirmTask?.cancel()
        confirmingOff = false
    }

    /// Second step: shut the tower down (or restart it into the same OS).
    func shutDown(_ mode: HubRPC.PowerOffParamsMode = .poweroff) {
        confirmTask?.cancel()
        confirmingOff = false
        guard stopping == nil, !isBooting else { return }
        offError = nil
        stopping = mode
        stopStarted = Date()
        sawDown = false
        Task {
            do {
                let data = try await backend.off(mode)
                let result = try JSONDecoder().decode(HubRPC.PowerOffResult.self, from: data)
                if !result.accepted {
                    stopping = nil
                    offError = "The server didn't take the request. The tower is still on."
                }
            } catch {
                stopping = nil
                offError = Self.offMessage(error)
            }
            await refresh()
            startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval: Double
                if self.isBooting || self.stopping != nil {
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
        if stopping != nil { followStop(state) }
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

    /// The shutdown this Mac asked for: done once power.state says off (a restart: once the
    /// tower went down and is back), or given up after the timeout.
    private func followStop(_ state: HubRPC.PowerStateResult) {
        guard let mode = stopping, let started = stopStarted else { return }
        let on: Set<HubRPC.PowerState> = [.omarchy, .windows]
        if !on.contains(state.state) { sawDown = true }
        let elapsed = Date().timeIntervalSince(started)
        switch mode {
        case .poweroff:
            if state.state == .off {
                stopping = nil
                HubActivity.shared.towerFinished(title: "Tower is off", subtitle: "Shut down from this Mac",
                                                 glyph: "hub.power", failed: false)
            } else if elapsed > Self.offTimeout {
                stopping = nil
                let now = Self.osName(state.state.rawValue).map { "on \($0)" } ?? Self.stateTitle(state.state).lowercased()
                offError = "The tower is still \(now) after \(Int(Self.offTimeout)) s. Something there may be holding up the shutdown."
            }
        case .reboot:
            if sawDown, on.contains(state.state) || state.state == .locked {
                stopping = nil
                HubActivity.shared.towerFinished(
                    title: state.state == .locked ? "Tower restarted" : "Tower is back on \(Self.osName(state.state.rawValue) ?? "")",
                    subtitle: state.state == .locked ? "Waiting for the disk unlock" : "Restarted from this Mac",
                    glyph: "hub.tower", failed: false)
            } else if elapsed > Self.rebootTimeout {
                stopping = nil
                offError = sawDown
                    ? "The tower went down but isn't back after \(Int(Self.rebootTimeout / 60)) min."
                    : "The tower is still on after \(Int(Self.rebootTimeout / 60)) min. Something there may be holding up the restart."
            }
        }
    }

    /// power.off's errors in the user's words (docs/BRAND.md voice).
    static func offMessage(_ error: Error) -> String {
        let (problem, message) = classify(error)
        guard let failure = error as? HubHelperClient.Failure, case .rpc(let code) = failure.kind else {
            if case .noHelper = problem { return "The hub helper isn't running. Restarting boring.notch starts it again." }
            return message
        }
        let text = failure.message.lowercased()
        if problem == .notSetUp {
            return "The server can't shut the tower down yet. It needs the newer hub."
        }
        switch code {
        case "invalid_params" where text.contains("boot"):
            return "The tower is still starting. Try again once it's up."
        case "unavailable" where text.contains("unlock") || text.contains("locked"):
            return "The tower is waiting for the disk unlock, so there's nothing to shut down."
        case "unavailable":
            return "The server can't reach the tower right now. It may already be going down. \(cleanMessage(failure.message))"
        default:
            return cleanMessage(failure.message)
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
            if text.contains("not paired") || (code == "module_disabled" && text.contains("\"peer\"")) {
                return (.notPaired, failure.message)
            }
            // Until the server runs the power module: "unavailable … not implemented yet";
            // an older server says unknown_method or module_disabled.
            // Only the server's own answers count (peer.call prefixes them with "server: "):
            // a disabled peer module here is this Mac's problem, not the server's.
            let fromServer = text.hasPrefix(serverDevice + ": ")
            if fromServer, code == "unknown_method" || code == "module_disabled"
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
        func off(_ mode: HubRPC.PowerOffParamsMode) async throws -> Data
    }

    struct ServerBackend: Backend {
        func state() async throws -> Data {
            try await HubHelperClient.peerCall(device: TowerModel.serverDevice, method: "power.state", timeoutMs: 8000)
        }

        func boot(_ os: HubRPC.PowerBootParamsOS) async throws -> Data {
            try await HubHelperClient.peerCall(device: TowerModel.serverDevice, method: "power.boot",
                                               params: ["os": os.rawValue], timeoutMs: 10_000)
        }

        func off(_ mode: HubRPC.PowerOffParamsMode) async throws -> Data {
            try await HubHelperClient.peerCall(device: TowerModel.serverDevice, method: "power.off",
                                               params: ["mode": mode.rawValue], timeoutMs: 10_000)
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
        confirmTask?.cancel()
        confirmingOff = false
        stopping = nil
        offError = nil
        refreshSoon()
    }
    #endif
}

#if DEBUG
/// A pretend server for agent tests and screenshots, so nobody powers on real hardware.
/// Scenarios: off, omarchy, windows, locked, relay_offline, not_set_up, failed, booting.
/// A boot runs waking 6 s, unlocking 2 s, starting 6 s (switching 3 s from a running OS),
/// and fails at unlocking when the scenario is `fail_boot`.
/// power.off (from omarchy/windows): on 3 s, not answering 5 s, then off; a restart comes
/// back after another 6 s. `off_stuck` never goes down, `off_refused` answers invalid_params
/// (a boot is running), `off_locked` answers unavailable (at the disk unlock).
actor FakeTowerBackend: TowerModel.Backend {
    private var scenario: String
    private var offStart: Date?
    private var offMode = "poweroff"
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
        case "off_stuck", "off_refused", "off_locked":
            out["state"] = "omarchy"
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
        if let start = offStart {
            let t = now.timeIntervalSince(start)
            if scenario != "off_stuck", t >= 3 {
                let back = scenario == "windows" ? "windows" : "omarchy"
                switch (offMode, t) {
                case (_, ..<8): out["state"] = "nossh"
                case ("reboot", ..<14): out["state"] = "nossh"
                case ("reboot", _): out["state"] = back
                default:
                    out["state"] = "off"
                    out["since"] = ISO8601DateFormatter().string(from: start.addingTimeInterval(8))
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    func off(_ mode: HubRPC.PowerOffParamsMode) async throws -> Data {
        switch scenario {
        case "not_set_up":
            throw HubHelperClient.Failure(kind: .rpc(code: "unknown_method"), message: "server: unknown method power.off")
        case "off_refused":
            throw HubHelperClient.Failure(kind: .rpc(code: "invalid_params"), message: "server: a power.boot is running; wait for it to finish")
        case "off_locked":
            throw HubHelperClient.Failure(kind: .rpc(code: "unavailable"), message: "server: the tower is at the disk unlock")
        default:
            break
        }
        let running = ["omarchy", "windows", "off_stuck"].contains(scenario)
        if running, offStart == nil {
            offStart = Date()
            offMode = mode.rawValue
        }
        return try JSONSerialization.data(withJSONObject: ["accepted": true, "state": running ? "omarchy" : "off"])
    }

    func boot(_ os: HubRPC.PowerBootParamsOS) async throws -> Data {
        if scenario == "not_set_up" {
            throw HubHelperClient.Failure(kind: .rpc(code: "unavailable"), message: "server: power.boot is not implemented yet")
        }
        from = ["omarchy", "windows"].contains(scenario) ? scenario : "off"
        if offStart != nil, offMode == "poweroff" {
            from = "off"
            offStart = nil
        }
        if scenario == "failed" { scenario = "off" }
        target = os.rawValue
        bootStart = Date()
        return try JSONSerialization.data(withJSONObject: ["accepted": true, "state": from, "eta_seconds": 14])
    }
}
#endif
