//
//  DictationActivity.swift
//  boringNotch
//

import Defaults
import Foundation
import SwiftUI

/// "Tower listening": the tower's dictation (hub-dictate, push-to-talk) shown live in the
/// closed notch while its mic is open (hub D-169).
///
/// The tower calls `dictate.state` on this Mac through the hub; the helper forwards it to the
/// agent bridge (`AgentBridgeRouter`), which lands here. `listening` arrives at the start and
/// then every 500 ms with the voice level and the target window; `ended` arrives the moment
/// the session is over. Two things keep a stale activity from sticking: every update is only
/// good for its `ttl_ms` (3 s by default), so a tower that went away (crash, sleep, network)
/// clears it by itself, and an `ended` for the shown session clears it at once.
///
/// What it shows: a mic and a level meter either side of the closed island
/// (`DictationLiveActivity` in ContentView) and, under it, the notch's sneak peek slot
/// (`SneakContentType.dictation`, `DictationPeekView`) with the running time and the window
/// the text will go to.
@MainActor
final class DictationActivity: ObservableObject {
    static let shared = DictationActivity()

    struct Session: Equatable {
        var id: String
        /// When listening began, on this Mac's clock (anchored on the sender's elapsed time).
        var startedAt: Date
        /// The window the text will be pasted into ("notes.md - nvim"), when the tower says.
        var target: String?
        var targetApp: String?
        /// Whose mic records (phone, tower), when the tower says.
        var mic: String?
    }

    enum Failure: Error { case invalid(String) }

    @Published private(set) var session: Session?
    /// 0...1, the latest level the tower sent; nil when it doesn't send one.
    @Published private(set) var level: Double?

    static let defaultTTL: TimeInterval = 3
    static let ttlRange: ClosedRange<TimeInterval> = 0.5...10
    /// Titles past this are cut (the contract's limit on what is shown).
    static let maxTarget = 200
    /// The sender's elapsed time is trusted over the first anchor only when they drift
    /// further apart than this, so network jitter never makes the timer step backwards.
    private static let reanchorDrift: TimeInterval = 1.5

    private var staleTask: Task<Void, Never>?
    private var lastPresent: Date = .distantPast

    private init() {}

    private var enabled: Bool { Defaults[.showTowerDictation] }

    var isActive: Bool { session != nil }

    /// One `dictate.state` call. Returns whether the activity is up afterwards.
    @discardableResult
    func update(sessionID: String, state: String, elapsedMs: Int?, startedAt: String?, ttlMs: Int?,
                level: Double?, target: String?, targetApp: String?, mic: String?) throws -> Bool {
        switch state {
        case "ended":
            if session?.id == sessionID { clear() }
            return false
        case "listening":
            break
        default:
            throw Failure.invalid("state must be listening or ended, not \(state)")
        }
        guard enabled else {
            clear()
            return false
        }

        let now = Date()
        let reported: Date? = elapsedMs.map { now.addingTimeInterval(-Double(max(0, $0)) / 1000) }
            ?? startedAt.flatMap(Self.parseDate)
        var next = Session(id: sessionID, startedAt: reported ?? now,
                           target: Self.clean(target).map { String($0.prefix(Self.maxTarget)) },
                           targetApp: Self.clean(targetApp), mic: Self.clean(mic)?.lowercased())
        if let current = session, current.id == sessionID {
            // Same session: keep the first anchor unless the sender's clock says otherwise.
            if let reported, abs(reported.timeIntervalSince(current.startedAt)) <= Self.reanchorDrift {
                next.startedAt = current.startedAt
            } else if reported == nil {
                next.startedAt = current.startedAt
            }
            if next != current { session = next }
        } else {
            withAnimation(.smooth) { session = next }
        }
        self.level = level.map { min(1, max(0, $0)) }

        let ttl = min(Self.ttlRange.upperBound, max(Self.ttlRange.lowerBound,
                                                    ttlMs.map { Double($0) / 1000 } ?? Self.defaultTTL))
        armStaleTimer(ttl)
        present(ttl: ttl)
        return true
    }

    /// Takes everything down: the strip, the peek, the timer.
    func clear() {
        staleTask?.cancel()
        staleTask = nil
        lastPresent = .distantPast
        if session != nil {
            withAnimation(.smooth) { session = nil }
        }
        level = nil
        let coordinator = BoringViewCoordinator.shared
        if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .dictation {
            coordinator.toggleSneakPeek(status: false, type: .dictation)
        }
    }

    // MARK: - Private

    private func armStaleTimer(_ ttl: TimeInterval) {
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ttl))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Keeps the peek under the island up while listening. The peek's own hide timer is set
    /// past the stale timeout, so `clear()` is always what takes it down. Re-armed at most once
    /// a second (each re-show is a state change), and never over another peek that is up
    /// (a volume change, a track change): the next update brings it back after that one.
    private func present(ttl: TimeInterval) {
        let coordinator = BoringViewCoordinator.shared
        let ours = coordinator.sneakPeek.show && coordinator.sneakPeek.type == .dictation
        if coordinator.sneakPeek.show && !ours { return }
        if ours && Date().timeIntervalSince(lastPresent) < 1 { return }
        lastPresent = Date()
        coordinator.toggleSneakPeek(status: true, type: .dictation, duration: ttl + 2)
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Views

/// Tower orange from the hub palette (brand/palette.json, dark `tower`), on the black island.
let dictationTint = Color(red: 0xEF / 255, green: 0xA0 / 255, blue: 0x4B / 255)

/// m:ss since `start`, ticking once a second.
struct DictationTimer: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let s = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .monospacedDigit()
        }
    }
}

/// A few bars driven by the voice level. Between the tower's updates (every 500 ms) the
/// bars move a little on their own, scaled by the last level, so the meter reads as live
/// instead of stepping twice a second; silence leaves them low and still.
struct DictationLevelBars: View {
    var level: Double?
    var bars = 4
    var color: Color = dictationTint

    private static let weights: [Double] = [0.55, 1.0, 0.8, 0.65, 0.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let base = level ?? 0.25
            GeometryReader { proxy in
                let gap: CGFloat = 2
                let w = max(1, (proxy.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<bars, id: \.self) { i in
                        let wobble = 0.5 + 0.5 * sin(t * (7 + Double(i) * 2.3) + Double(i) * 1.7)
                        let weight = Self.weights[i % Self.weights.count]
                        let v = min(1, base * weight * (0.65 + 0.35 * wobble))
                        Capsule()
                            .fill(color)
                            .frame(width: w, height: max(w, proxy.size.height * (0.15 + 0.85 * v)))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .animation(.linear(duration: 0.12), value: level)
    }
}

/// The line under the island while the tower listens, in the slot and type pairing of the
/// music and hub peeks: 11 semibold white over 9 at half white.
struct DictationPeekView: View {
    @ObservedObject var activity = DictationActivity.shared

    private static let maxTextColumn: CGFloat = 190
    private static let iconSide: CGFloat = 18

    var body: some View {
        if let session = activity.session {
            HStack(spacing: 7) {
                // Who is listening; the strip above already carries the mic.
                Image("hub.tower")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("Tower listening")
                        Text("·").foregroundStyle(.white.opacity(0.5))
                        DictationTimer(start: session.startedAt)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    Text(Self.subtitle(for: session))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: Self.maxTextColumn, alignment: .leading)
                }
            }
            .padding(.vertical, 1)
            .fixedSize()
        }
    }

    static func subtitle(for session: DictationActivity.Session) -> String {
        if let target = session.target { return "Into \(target)" }
        if let app = session.targetApp { return "Into \(app)" }
        switch session.mic {
        case "phone": return "Phone mic"
        case "tower": return "Tower mic"
        default: return "Speak now"
        }
    }
}
