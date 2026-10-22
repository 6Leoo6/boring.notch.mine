//
//  TowerView.swift
//  boringNotch
//
//  The open notch's Tower tab (remote wake, hub D-145): what the tower is doing, Wake
//  (into Omarchy) and Windows, the steps of a boot while it runs, and why it didn't
//  start with Retry. Words follow the hub's docs/BRAND.md: name the device, say what
//  happened and what to do next.
//

import SwiftUI

struct TowerView: View {
    @ObservedObject var model = TowerModel.shared
    /// The failure the user closed (keyed by the boot's start), so it stays closed.
    @State private var dismissedFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.3), value: model.power)
        .animation(.smooth(duration: 0.3), value: model.problem)
        .animation(.smooth(duration: 0.3), value: model.requested)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if let problem = model.problem {
            problemRow(problem)
        } else if model.isBooting {
            bootingRows
        } else if let error = model.requestError {
            failureRow(title: "Tower didn't start", detail: error)
        } else if let power = model.power, power.phase == .failed, dismissedFailure != (power.started ?? "") {
            failureRow(title: "Tower didn't start", detail: power.error ?? power.detail ?? "No reason given")
        } else if let power = model.power {
            idleRow(power)
        } else {
            row(glyph: "hub.tower", tint: .white.opacity(0.35), title: "Tower",
                detail: "Asking the server…", caption: nil) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func idleRow(_ power: HubRPC.PowerStateResult) -> some View {
        let relayDown = power.relay?.online == false
        let needsRelay = [.off, .suspended, .unknown].contains(power.state)
        return row(glyph: Self.glyph(for: power.state), tint: Self.tint(for: power.state),
                   title: "Tower", detail: TowerModel.stateTitle(power.state),
                   caption: caption(power), captionIsWarning: relayDown) {
            HStack(spacing: 8) {
                switch power.state {
                case .omarchy:
                    TowerButton(title: "Switch to Windows", glyph: "hub.windows", primary: false) { model.boot(.windows) }
                case .windows:
                    TowerButton(title: "Switch to Omarchy", glyph: "hub.tower", primary: false) { model.boot(.omarchy) }
                default:
                    TowerButton(title: "Windows", glyph: "hub.windows", primary: false) { model.boot(.windows) }
                        .disabled(relayDown && needsRelay)
                    TowerButton(title: "Wake", glyph: "hub.wake", primary: true) { model.boot(.omarchy) }
                        .disabled(relayDown && needsRelay)
                }
            }
        }
    }

    private var bootingRows: some View {
        let power = model.power
        let target = model.requested?.rawValue ?? power?.target?.rawValue
        let os = TowerModel.osName(target) ?? "Omarchy"
        let phase = model.requested != nil ? nil : power?.phase
        let steps = Self.steps(target: target, switching: model.seenSwitching || phase == .switching)
        let current = phase.flatMap { p in steps.firstIndex { $0.phases.contains(p) } } ?? 0
        let eta = power?.etaSeconds.map { "about \(Self.duration($0)) left" }
        return VStack(alignment: .leading, spacing: 12) {
            row(glyph: target == "windows" ? "hub.windows" : "hub.wake", tint: .white,
                title: "Starting \(os)",
                detail: model.requested != nil ? "Asking the server" : (power?.detail ?? steps[current].active),
                caption: eta) {
                EmptyView() // the current step pulses below
            }
            TowerSteps(steps: steps.map(\.label), current: current)
        }
    }

    private func failureRow(title: String, detail: String) -> some View {
        row(glyph: "hub.error", tint: .white, title: title, detail: detail, caption: nil) {
            HStack(spacing: 8) {
                TowerButton(title: "Dismiss", glyph: nil, primary: false) {
                    if model.requestError != nil {
                        model.dismissError()
                    } else {
                        dismissedFailure = model.power?.started ?? ""
                    }
                }
                TowerButton(title: "Retry", glyph: "hub.sync", primary: true) {
                    dismissedFailure = nil
                    model.retry()
                }
            }
        }
    }

    @ViewBuilder
    private func problemRow(_ problem: TowerModel.Problem) -> some View {
        switch problem {
        case .notSetUp:
            row(glyph: "hub.warning", tint: .white.opacity(0.6), title: "Wake isn't set up on the server yet",
                detail: "The server answered but has no wake running. Nothing to do here for now.", caption: nil) {
                checkAgain
            }
        case .noHelper(let reason):
            row(glyph: "hub.offline", tint: .white.opacity(0.6), title: "The hub helper isn't running",
                detail: "Wake goes through it. Restarting boring.notch starts it again.", caption: reason) {
                checkAgain
            }
        case .notPaired:
            row(glyph: "hub.pair", tint: .white.opacity(0.6), title: "This Mac isn't on the hub yet",
                detail: "Pair the hub helper, then the tower shows up here.", caption: nil) {
                checkAgain
            }
        case .unreachable(let reason):
            row(glyph: "hub.offline", tint: .white.opacity(0.6), title: "Can't reach the server",
                detail: reason, caption: "Wake needs the hub server online.") {
                checkAgain
            }
        }
    }

    private var checkAgain: some View {
        TowerButton(title: "Check again", glyph: nil, primary: false) { model.refreshSoon() }
    }

    // MARK: - Pieces

    private func row<Trailing: View>(glyph: String, tint: Color, title: String, detail: String,
                                     caption: String?, captionIsWarning: Bool = false,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 54, height: 54)
                .overlay {
                    Image(glyph)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(tint)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                if let caption {
                    HStack(spacing: 4) {
                        if captionIsWarning {
                            Image("hub.warning").renderingMode(.template).resizable().frame(width: 10, height: 10)
                        }
                        Text(caption).lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(captionIsWarning ? .white.opacity(0.75) : .white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }

    private func caption(_ power: HubRPC.PowerStateResult) -> String? {
        if let relay = power.relay, !relay.online {
            if let seen = relay.lastSeen.flatMap(Self.parse) {
                return "Wake relay at home is offline · last seen \(Self.clock(seen))"
            }
            return "Wake relay at home is offline"
        }
        if power.phase == .done, let started = power.started.flatMap(Self.parse) {
            return "Woken from this Mac at \(Self.clock(started))"
        }
        if let since = power.since.flatMap(Self.parse) {
            return "Since \(Self.clock(since))"
        }
        return nil
    }

    // MARK: - Steps

    struct Step {
        let label: String
        let active: String
        let phases: Set<HubRPC.PowerStateResultPhase>
    }

    static func steps(target: String?, switching: Bool) -> [Step] {
        let os = TowerModel.osName(target) ?? "Omarchy"
        if switching {
            return [Step(label: "Restart", active: "Restarting into \(os)", phases: [.switching]),
                    Step(label: "Start \(os)", active: "\(os) is starting", phases: [.starting]),
                    Step(label: "Ready", active: "Ready", phases: [.done])]
        }
        return [Step(label: "Wake", active: "Waiting for the tower to wake", phases: [.waking, .idle]),
                Step(label: target == "windows" ? "Pick Windows" : "Unlock", active: target == "windows" ? "Choosing Windows for this boot" : "Unlocking the disk", phases: [.unlocking]),
                Step(label: "Start \(os)", active: "\(os) is starting", phases: [.starting]),
                Step(label: "Ready", active: "Ready", phases: [.done])]
    }

    // MARK: - Words and looks

    static func glyph(for state: HubRPC.PowerState) -> String {
        switch state {
        case .omarchy, .nossh: return "hub.tower"
        case .windows: return "hub.windows"
        case .locked: return "hub.lock"
        case .off, .suspended, .unknown: return "hub.power"
        }
    }

    static func tint(for state: HubRPC.PowerState) -> Color {
        switch state {
        case .omarchy, .windows: return .white
        case .locked, .nossh: return .white.opacity(0.75)
        case .off, .suspended, .unknown: return .white.opacity(0.4)
        }
    }

    static func duration(_ seconds: Int64) -> String {
        seconds < 60 ? "\(max(1, seconds)) s" : "\((seconds + 30) / 60) min"
    }

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}

/// The steps of a boot as a row of dots joined by lines: done ones filled, the current one
/// pulsing, the rest hollow.
struct TowerSteps: View {
    let steps: [String]
    let current: Int

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Capsule()
                        .fill(.white.opacity(index <= current ? 0.7 : 0.15))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(index <= current ? 0.9 : 0.3), lineWidth: 1.5)
                            .frame(width: 12, height: 12)
                        if index < current {
                            Image("hub.check").renderingMode(.template).resizable().frame(width: 9, height: 9)
                                .foregroundStyle(.white)
                        } else if index == current {
                            Circle().fill(.white).frame(width: 6, height: 6)
                                .opacity(pulse ? 0.35 : 1)
                        }
                    }
                    Text(label)
                        .font(.system(size: 11, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(index <= current ? 0.9 : 0.4))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct TowerButton: View {
    let title: String
    let glyph: String?
    let primary: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph {
                    Image(glyph).renderingMode(.template).resizable().frame(width: 13, height: 13)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(primary ? .black : .white)
            .background(
                Capsule().fill(primary ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.2 : 0.12))
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
