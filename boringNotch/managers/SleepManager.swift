//
//  SleepManager.swift
//  boringNotch
//

import Defaults
import Foundation
import IOKit.pwr_mgt

@MainActor
final class SleepManager: ObservableObject {
    static let shared = SleepManager()

    @Published private(set) var isKeepingAwake: Bool = false
    @Published private(set) var expiresAt: Date?

    // ASCII only: pmset -g assertions, the tool anyone would use to inspect this, emits an
    // invalid byte for a non-ASCII character in the name and corrupts its whole output.
    private static let assertionName = "boring.notch keep awake"

    private var assertionID: IOPMAssertionID?
    private var assertionPreventsDisplaySleep = false
    private var expiryTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public

    func restoreOnLaunch() {
        guard Defaults[.keepAwakeRestoreOnLaunch] else {
            // Drop the remembered state so switching the preference on later in this
            // session cannot resurrect a toggle from some much earlier run.
            Defaults[.keepAwakeWasActive] = false
            return
        }
        guard Defaults[.keepAwakeWasActive] else { return }
        enable()
    }

    func toggle() {
        if isKeepingAwake {
            disable()
        } else {
            enable()
        }
    }

    func enable() {
        guard acquireAssertion() else { return }
        Defaults[.keepAwakeWasActive] = true
        armExpiry(after: Defaults[.keepAwakeDuration].seconds)
    }

    func disable() {
        Defaults[.keepAwakeWasActive] = false
        disarmExpiry()
        releaseAssertion()
    }

    /// The OS reclaims a process-owned assertion on exit — crash included — so this is
    /// belt and braces, not the guarantee. It deliberately leaves `keepAwakeWasActive`
    /// alone so the restore-on-launch preference still sees the state the user chose.
    func releaseForTermination() {
        disarmExpiry()
        releaseAssertion()
    }

    /// Swap the live assertion when the display-sleep preference changes mid-session,
    /// preserving any pending expiry.
    func reapplyDisplaySleepPreference() {
        guard isKeepingAwake,
              assertionPreventsDisplaySleep != Defaults[.keepAwakePreventsDisplaySleep]
        else { return }
        releaseAssertion()
        _ = acquireAssertion()
    }

    /// Wall-clock end time of a bounded session, formatted for display. Deliberately not a
    /// countdown: the notch header cannot re-layout every second without causing real bugs.
    var expiryDescription: String? {
        guard let expiresAt else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: expiresAt)
    }

    // MARK: - Assertion

    private func acquireAssertion() -> Bool {
        if assertionID != nil { return true }

        let preventDisplaySleep = Defaults[.keepAwakePreventsDisplaySleep]
        // PreventUserIdleDisplaySleep implies system sleep prevention too, so one
        // assertion covers both cases; only the type differs.
        let type = preventDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep

        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            NSLog("[SleepManager] IOPMAssertionCreateWithName failed: \(result)")
            return false
        }

        assertionID = id
        assertionPreventsDisplaySleep = preventDisplaySleep
        isKeepingAwake = true
        return true
    }

    private func releaseAssertion() {
        guard let id = assertionID else {
            isKeepingAwake = false
            return
        }
        // Clear first: releasing an ID twice returns kIOReturnNotFound and would mean we
        // no longer know what we own.
        assertionID = nil
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            NSLog("[SleepManager] IOPMAssertionRelease failed: \(result)")
        }
        isKeepingAwake = false
    }

    // MARK: - Expiry

    private func armExpiry(after seconds: TimeInterval?) {
        disarmExpiry()
        guard let seconds, seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        expiresAt = deadline
        expiryTask = Task { [weak self] in
            // Nap in bounded steps and re-check the wall clock each time. A system sleep or
            // app suspension stretches a single long nap unpredictably; checking `Date`
            // means elapsed real time is what counts, and the overshoot after a wake is
            // bounded by the step rather than by however long the machine was out.
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                do {
                    try await Task.sleep(for: .seconds(min(remaining, 30)))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    private func disarmExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        expiresAt = nil
    }

    private func expire() {
        Defaults[.keepAwakeWasActive] = false
        disarmExpiry()
        releaseAssertion()
    }
}
