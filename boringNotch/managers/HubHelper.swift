//
//  HubHelper.swift
//  boringNotch
//
//  Keeps the hub helper registered: towerbridge, embedded in this app by the
//  "Embed hub helper" build phase (Hub/embed-helper.sh) as Contents/Helpers/
//  HubHelper.app, runs as a LaunchAgent through SMAppService. It keeps this Mac
//  on the hub mesh and answers the other devices through this app's own agent
//  bridge (/rpc). See 6Leoo6/hub, decision D-128. Builds without the binary
//  simply skip it.
//
//  Two variants, chosen at build time (embed-helper.sh):
//  - release: label io.github.leoo6.hub.helper, Helpers/HubHelper.app, port 47821.
//  - dev (ad-hoc signed or HUB_HELPER_VARIANT=dev builds): label
//    io.github.leoo6.hub.helper.dev, Helpers/HubHelperDev.app, port 47822, its own
//    sandbox container. A dev build never touches the release helper's container
//    (macOS asks before a differently signed helper opens it) or its registration,
//    and unregisters its own helper when it quits.
//

import CryptoKit
import Foundation
import Network
import ServiceManagement
import os

enum HubHelper {
    private struct Variant {
        let label: String
        let bundleName: String
        /// Where the helper listens (towerbridge's default, or the dev plist's --listen).
        let port: UInt16
        let isDev: Bool

        var plistName: String { label + ".plist" }
        /// Per variant: release and dev builds share this app's defaults domain.
        var registeredKey: String { isDev ? "hubHelperRegisteredFingerprint.dev" : "hubHelperRegisteredFingerprint" }
    }

    private static let variants = [
        Variant(label: "io.github.leoo6.hub.helper", bundleName: "HubHelper.app", port: 47821, isDev: false),
        Variant(label: "io.github.leoo6.hub.helper.dev", bundleName: "HubHelperDev.app", port: 47822, isDev: true),
    ]

    private static let log = Logger(subsystem: "boring.notch.mine", category: "HubHelper")

    private static var agentsDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
    }

    /// The variant this build carries, if any (the build phase skips the helper when
    /// no towerbridge binary was available).
    private static let variant: Variant? = variants.first {
        FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent($0.plistName).path)
    }

    static var isEmbedded: Bool { variant != nil }

    private static func service(_ v: Variant) -> SMAppService { SMAppService.agent(plistName: v.plistName) }

    private static func helperExecutable(_ v: Variant) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(v.bundleName)/Contents/MacOS/towerbridge")
    }

    /// launchd keeps the job it was given at registration, tied to the bundle it came
    /// from. So the fingerprint covers the plist, the helper binary, and this bundle's
    /// identity on disk (path, inode, creation date): replacing the app with an
    /// identical copy (rm + ditto) leaves the registration pointing at the deleted
    /// bundle ("copy_bundle_path(...) Invalid or missing Program", exit 78), and only a
    /// fresh registration fixes that.
    private static func fingerprint(_ v: Variant) -> String? {
        guard let plist = try? Data(contentsOf: agentsDir.appendingPathComponent(v.plistName)),
              let helper = try? Data(contentsOf: helperExecutable(v), options: .mappedIfSafe) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var hash = SHA256()
        hash.update(data: Data("\(Bundle.main.bundlePath)\n\(inode)\n\(created)\n".utf8))
        hash.update(data: plist)
        hash.update(data: helper)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Called once at launch. Registers the helper if it isn't yet (or if it
    /// changed); macOS then starts it at login and keeps it running. Then checks that
    /// it really answers and registers it again once if not. Runs off the main
    /// thread: it hashes the helper and makes synchronous calls to smd.
    static func registerIfEmbedded() {
        DispatchQueue.global(qos: .utility).async {
            guard let v = variant else {
                log.info("hub helper not embedded in this build; skipping")
                return
            }
            sync(v)
            verifyRunning(v)
        }
    }

    /// Called from applicationWillTerminate. A dev build's helper lives only as long
    /// as the dev build runs: left registered, launchd would keep trying to start it
    /// from whichever copy of this app ran last, which has no dev helper.
    static func unregisterDevHelperOnQuit() {
        guard let v = variant, v.isDev else { return }
        do {
            try service(v).unregister()
            UserDefaults.standard.removeObject(forKey: v.registeredKey)
            log.info("dev hub helper unregistered on quit")
        } catch {
            log.error("dev hub helper unregister failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sync(_ v: Variant) {
        let current = fingerprint(v)
        let upToDate = current != nil && UserDefaults.standard.string(forKey: v.registeredKey) == current

        switch service(v).status {
        case .enabled where upToDate:
            log.info("hub helper \(v.label, privacy: .public) enabled")
        case .requiresApproval where upToDate:
            log.notice("hub helper needs approval: System Settings > General > Login Items & Extensions")
        case .enabled, .requiresApproval:
            reregister(v, fingerprint: current, reason: "changed")
        default:
            register(v, fingerprint: current)
        }
    }

    /// Unregister, then register again once the old one is really gone: registering
    /// right after unregister() leaves launchd pointing at the removed login item
    /// ("copy_bundle_path(...) Invalid or missing Program"), and the helper never starts.
    private static func reregister(_ v: Variant, fingerprint: String?, reason: String) {
        let svc = service(v)
        do {
            try svc.unregister()
            log.info("hub helper \(reason, privacy: .public); unregistered the old one")
        } catch {
            log.error("hub helper unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        for _ in 0..<20 where svc.status != .notRegistered {
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 2)
        register(v, fingerprint: fingerprint)
    }

    private static func register(_ v: Variant, fingerprint: String?) {
        let svc = service(v)
        do {
            try svc.register()
            UserDefaults.standard.set(fingerprint, forKey: v.registeredKey)
            log.info("hub helper \(v.label, privacy: .public) registered (status \(svc.status.rawValue))")
        } catch {
            log.error("hub helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The registration can look fine (status .enabled, fingerprint unchanged) while
    /// launchd can't start the job, or the helper hangs before it listens. Give it
    /// time to start (launchd throttles respawns to 10 s), then re-register once per
    /// launch if nothing answers on its port.
    private static func verifyRunning(_ v: Variant) {
        guard service(v).status == .enabled else { return }
        if waitForHelper(v) { return }
        log.error("hub helper \(v.label, privacy: .public) isn't answering on port \(v.port); registering it again")
        reregister(v, fingerprint: fingerprint(v), reason: "not answering")
        if waitForHelper(v) {
            log.info("hub helper answers after re-registering")
        } else {
            log.error("hub helper still isn't answering; see launchctl print gui/$UID/\(v.label, privacy: .public)")
        }
    }

    private static func waitForHelper(_ v: Variant) -> Bool {
        Thread.sleep(forTimeInterval: 15)
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 10) }
            if isListening(port: v.port) { return true }
        }
        return false
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Whether something accepts TCP connections on 127.0.0.1:port.
    private static func isListening(port: UInt16) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let ready = Flag()
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.set()
                done.signal()
            case .failed, .waiting, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = done.wait(timeout: .now() + 3)
        connection.cancel()
        return ready.get()
    }
}
