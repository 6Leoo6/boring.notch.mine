//
//  LiveActivities.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// Notch live activities from the mesh (hub D-170): what the other devices are doing right
/// now, one at a time in the closed notch's peek slot, with a count of the rest.
///
/// Any device calls `activity.update` / `activity.end` on this Mac through the hub; the helper
/// forwards them to the agent bridge (`AgentBridgeRouter`) with `source` set to the calling
/// device, and they land here, keyed by source + id. The tower relays its own (files it
/// receives, `towerbridge send`, the phone's battery) and any script can add one.
///
/// Nothing sticks: every update is only good for its `ttl_ms` (30 s by default, 1 s to
/// 10 min), so an activity whose producer went away clears by itself, and `ended` clears it at
/// once. The tower's dictation (`DictationActivity`, its own `dictate.state`) always comes
/// first: while it listens it holds the peek and this one waits, counted in its badge. Then
/// by kind (transfer, battery, ci, job, alert, other), the newest first within a kind.
@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    enum Kind: String, CaseIterable {
        case dictation, transfer, battery, ci, job, alert, other

        var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }

        /// Hub icon (`HubIcons.xcassets`) when the producer names none or one this build lacks.
        var icon: String {
            switch self {
            case .dictation: return "hub.mic"
            case .transfer: return "hub.shelf"
            case .battery: return "hub.battery"
            case .ci, .job: return "hub.job"
            case .alert: return "hub.warning"
            case .other: return "hub.peek"
            }
        }
    }

    struct Action: Equatable {
        var id: String
        var label: String
        var url: URL
    }

    struct Activity: Identifiable, Equatable {
        /// source + "/" + the producer's id.
        let id: String
        let source: String
        let key: String
        var kind: Kind
        var title: String
        var subtitle: String?
        var progress: Double?
        /// Asset name of the icon to draw.
        var icon: String
        /// When it began on this Mac's clock, for the running m:ss; nil: no timer.
        var startedAt: Date?
        var actions: [Action]
        let createdAt: Date
        var expires: Date
    }

    enum Failure: Error { case invalid(String) }

    /// Up right now, in the order they would be shown.
    @Published private(set) var activities: [Activity] = []

    static let defaultTTL: TimeInterval = 30
    static let ttlRange: ClosedRange<TimeInterval> = 1...600
    /// Rate limit per source (roadmap: "so a busy job doesn't keep the notch open"): a source's
    /// ninth activity replaces its oldest; past `maxTotal` the lowest-priority one goes.
    static let maxPerSource = 8
    static let maxTotal = 24
    static let maxTitle = 80
    static let maxSubtitle = 120
    static let maxActionLabel = 16
    private static let reanchorDrift: TimeInterval = 1.5

    private var tickTask: Task<Void, Never>?
    private var lastPresent: Date = .distantPast
    private var shownID: String?

    private init() {}

    private var enabled: Bool { Defaults[.showLiveActivities] }

    var top: Activity? { activities.first }

    /// Everything up on this Mac, the tower's dictation included (the contract's `count`).
    var count: Int { activities.count + (DictationActivity.shared.isActive ? 1 : 0) }

    // MARK: - Calls (agent bridge)

    struct Update {
        var source: String
        var id: String
        var state: String
        var kind: String?
        var title: String?
        var subtitle: String?
        var progress: Double?
        var icon: String?
        var startedAt: String?
        var elapsedMs: Int?
        var ttlMs: Int?
        var actions: [[String: Any]]
    }

    /// One `activity.update`. Returns whether it is up afterwards.
    @discardableResult
    func update(_ u: Update) throws -> Bool {
        let key = u.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.invalid("id is required") }
        guard key.count <= 128 else { throw Failure.invalid("id is longer than 128 characters") }
        let id = u.source + "/" + key
        switch u.state {
        case "ended":
            remove(id)
            return false
        case "active":
            break
        default:
            throw Failure.invalid("state must be active or ended, not \(u.state)")
        }
        guard let title = Self.clean(u.title) else { throw Failure.invalid("title is required with state active") }
        guard enabled else {
            clearAll()
            return false
        }

        let now = Date()
        let ttl = min(Self.ttlRange.upperBound, max(Self.ttlRange.lowerBound,
                                                    u.ttlMs.map { Double($0) / 1000 } ?? Self.defaultTTL))
        let kind = u.kind.flatMap(Kind.init(rawValue:)) ?? .other
        let reported: Date? = u.elapsedMs.map { now.addingTimeInterval(-Double(max(0, $0)) / 1000) }
            ?? u.startedAt.flatMap(Self.parseDate)
        let existing = activities.first { $0.id == id }
        var startedAt = reported
        if let reported, let previous = existing?.startedAt,
           abs(reported.timeIntervalSince(previous)) <= Self.reanchorDrift {
            startedAt = previous // keep the first anchor: jitter never steps the timer back
        }
        let next = Activity(
            id: id, source: u.source, key: key, kind: kind,
            title: String(title.prefix(Self.maxTitle)),
            subtitle: Self.clean(u.subtitle).map { String($0.prefix(Self.maxSubtitle)) },
            progress: u.progress.map { min(1, max(0, $0)) },
            icon: Self.iconName(u.icon, kind: kind),
            startedAt: startedAt,
            actions: u.actions.compactMap(Self.action).prefix(2).map { $0 },
            createdAt: existing?.createdAt ?? now,
            expires: now.addingTimeInterval(ttl)
        )
        var list = activities.filter { $0.id != id }
        list.append(next)
        list = Self.limited(Self.sorted(list))
        if existing == nil {
            withAnimation(.smooth) { activities = list }
        } else if list != activities {
            activities = list
        }
        startTicking()
        sync()
        return activities.contains { $0.id == id }
    }

    /// One `activity.end`. Ending an id that isn't up is fine.
    func end(source: String, id: String) {
        remove(source + "/" + id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Off switch, or the owner turned it off: everything goes.
    func clearAll() {
        guard !activities.isEmpty else { hideIfOurs(); return }
        withAnimation(.smooth) { activities = [] }
        hideIfOurs()
    }

    /// The dictation ended (or anything else freed the peek): show the next one, if any.
    func refresh() {
        prune()
        sync()
    }

    /// The tap: the first action, if it has one (https only, checked on the way in).
    func performPrimary() {
        guard let action = top?.actions.first else { return }
        NSWorkspace.shared.open(action.url)
        BoringViewCoordinator.shared.toggleSneakPeek(status: false, type: .live)
    }

    // MARK: - Private

    private func remove(_ id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        withAnimation(.smooth) { activities.removeAll { $0.id == id } }
        sync()
    }

    private func prune() {
        let now = Date()
        if activities.contains(where: { $0.expires <= now }) {
            withAnimation(.smooth) { activities.removeAll { $0.expires <= now } }
        }
    }

    /// While anything is up, once a second: drop what ran out and put the peek back when
    /// another peek (a volume change, an arrival) had taken the slot.
    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.prune()
                self.sync()
                if self.activities.isEmpty {
                    self.tickTask = nil
                    return
                }
            }
        }
    }

    /// Puts the peek up for the top activity, or takes ours down when nothing is left.
    /// Never over the dictation, and never over another peek that is up (the tick brings it
    /// back after that one); re-armed at most once a second, with a hide timer past the
    /// activity's own expiry so `prune` is what takes it down.
    private func sync() {
        let coordinator = BoringViewCoordinator.shared
        let ours = coordinator.sneakPeek.show && coordinator.sneakPeek.type == .live
        guard let top, enabled else {
            hideIfOurs()
            return
        }
        if DictationActivity.shared.isActive {
            if ours { coordinator.toggleSneakPeek(status: false, type: .live) }
            return
        }
        if coordinator.sneakPeek.show && !ours { return }
        if ours && shownID == top.id && Date().timeIntervalSince(lastPresent) < 1 { return }
        lastPresent = Date()
        shownID = top.id
        let left = max(1, top.expires.timeIntervalSinceNow)
        coordinator.toggleSneakPeek(status: true, type: .live, duration: left + 2)
    }

    private func hideIfOurs() {
        shownID = nil
        let coordinator = BoringViewCoordinator.shared
        if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .live {
            coordinator.toggleSneakPeek(status: false, type: .live)
        }
    }

    static func sorted(_ list: [Activity]) -> [Activity] {
        list.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            return a.createdAt > b.createdAt
        }
    }

    /// Applies the per-source and total caps to a sorted list (oldest of a source goes first,
    /// then the lowest priority).
    static func limited(_ list: [Activity]) -> [Activity] {
        var out = list
        for source in Set(out.map(\.source)) {
            let mine = out.filter { $0.source == source }
            if mine.count > maxPerSource {
                let drop = Set(mine.sorted { $0.createdAt < $1.createdAt }.prefix(mine.count - maxPerSource).map(\.id))
                out.removeAll { drop.contains($0.id) }
            }
        }
        if out.count > maxTotal { out = Array(out.prefix(maxTotal)) }
        return out
    }

    static func iconName(_ raw: String?, kind: Kind) -> String {
        if let name = clean(raw)?.lowercased() {
            let asset = name.hasPrefix("hub.") ? name : "hub." + name
            if NSImage(named: asset) != nil { return asset }
        }
        return kind.icon
    }

    static func action(_ raw: [String: Any]) -> Action? {
        guard let id = clean(raw["id"] as? String), let label = clean(raw["label"] as? String),
              let s = raw["url"] as? String, let url = URL(string: s), url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return Action(id: id, label: String(label.prefix(maxActionLabel)), url: url)
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

/// "+2": how many more are up than the peek shows. Fixed width per digit count, so the peek
/// doesn't twitch when the number changes.
struct LiveCountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("+\(min(count, 99))")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(.white.opacity(0.14)))
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// The line under the island for the top live activity, in the slot and type pairing of the
/// music, hub and dictation peeks: an icon, 11 semibold white over 9 at half white, a 2pt
/// progress line when it has one, the action as a small chip and the count of the others.
struct LivePeekView: View {
    @ObservedObject var center = LiveActivityCenter.shared

    private static let maxTextColumn: CGFloat = 190
    private static let iconSide: CGFloat = 18
    private static let iconGap: CGFloat = 7
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 9, weight: .regular)

    var body: some View {
        if let activity = center.top {
            let column = textColumn(for: activity)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Self.iconGap) {
                    Image(activity.icon)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        .foregroundStyle(.white.opacity(0.8))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(activity.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let start = activity.startedAt {
                                Text("·").foregroundStyle(.white.opacity(0.5))
                                DictationTimer(start: start)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: Self.maxTextColumn, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        if let subtitle = activity.subtitle {
                            Text(subtitle)
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: Self.maxTextColumn, alignment: .leading)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if let action = activity.actions.first {
                        Text(action.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .fixedSize()
                    }
                    LiveCountBadge(count: center.activities.count - 1)
                }
                if let progress = activity.progress {
                    ProgressLine(fraction: progress)
                        .frame(width: Self.iconSide + Self.iconGap + column, height: 2)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 1)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture { center.performPrimary() }
            .animation(.smooth, value: activity.id)
        }
    }

    private func textColumn(for a: LiveActivityCenter.Activity) -> CGFloat {
        let title = Self.width(of: a.title, font: Self.titleFont) + (a.startedAt == nil ? 0 : 34)
        let sub = Self.width(of: a.subtitle ?? "", font: Self.subtitleFont)
        return min(max(title, sub, 24), Self.maxTextColumn)
    }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}
