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

import CryptoKit
import Foundation
import ServiceManagement
import os

enum HubHelper {
    static let plistName = "io.github.leoo6.hub.helper.plist"
    private static let log = Logger(subsystem: "boring.notch.mine", category: "HubHelper")
    private static let registeredKey = "hubHelperRegisteredFingerprint"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    private static var agentPlist: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    private static var helperExecutable: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/HubHelper.app/Contents/MacOS/towerbridge")
    }

    /// Whether this build carries the helper (the build phase skips it when no
    /// towerbridge binary was available).
    static var isEmbedded: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path)
    }

    /// Hash of the agent plist and the helper binary. launchd keeps the job it was
    /// given at registration, so a changed plist or helper (an update, or a dev
    /// build in another place) means unregister and register again.
    private static var fingerprint: String? {
        guard let plist = try? Data(contentsOf: agentPlist),
              let helper = try? Data(contentsOf: helperExecutable, options: .mappedIfSafe) else { return nil }
        var hash = SHA256()
        hash.update(data: Data(Bundle.main.bundlePath.utf8))
        hash.update(data: plist)
        hash.update(data: helper)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Called once at launch. Registers the helper if it isn't yet (or if it
    /// changed); macOS then starts it at login and keeps it running. Runs off the
    /// main thread: it hashes the helper and makes synchronous calls to smd.
    static func registerIfEmbedded() {
        DispatchQueue.global(qos: .utility).async { sync() }
    }

    private static func sync() {
        guard isEmbedded else {
            log.info("hub helper not embedded in this build; skipping")
            return
        }
        let current = fingerprint
        let upToDate = current != nil && UserDefaults.standard.string(forKey: registeredKey) == current

        switch service.status {
        case .enabled where upToDate:
            log.info("hub helper enabled")
        case .requiresApproval where upToDate:
            log.notice("hub helper needs approval: System Settings > General > Login Items & Extensions")
        case .enabled, .requiresApproval:
            // Unregister, then register again once the old one is really gone:
            // registering right after unregister() leaves launchd pointing at the
            // removed login item ("copy_bundle_path(...) Invalid or missing Program"),
            // and the helper never starts.
            do {
                try service.unregister()
                log.info("hub helper changed; unregistered the old one")
            } catch {
                log.error("hub helper unregister failed: \(error.localizedDescription, privacy: .public)")
            }
            for _ in 0..<20 where service.status != .notRegistered {
                Thread.sleep(forTimeInterval: 0.25)
            }
            Thread.sleep(forTimeInterval: 2)
            register(fingerprint: current)
        default:
            register(fingerprint: current)
        }
    }

    private static func register(fingerprint: String?) {
        do {
            try service.register()
            UserDefaults.standard.set(fingerprint, forKey: registeredKey)
            log.info("hub helper registered (status \(service.status.rawValue))")
        } catch {
            log.error("hub helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
