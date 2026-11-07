//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//  Hub send (hub D-178): the drop zone sends to a hub device.
//
//  Drop files, text or links on it and they go to the chosen device (the last used one;
//  the zone shows its name). Click it for the device list, "Send files…" and "More…"
//  (the System Share Menu). While a send runs the zone shows a ring, the line "Sending to
//  phone · 1.2 of 5.4 GB · 3 min" and Cancel; then "On phone" / "Already on phone" /
//  "Didn't arrive: <why>" with Retry.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var hub = HubSendService.shared
    @Default(.hubSendDevice) private var hubSendDevice: String
    @Default(.showSystemShareMenu) private var showSystemShareMenu: Bool

    @State private var hostView: NSView?
    @State private var isProcessing = false
    @State private var dismissTask: Task<Void, Never>?

    private var device: HubSendDevice? {
        HubSendTargets.defaultDevice(targets: hub.targets, lastUsed: hubSendDevice)
    }

    private var batch: HubSendBatch? { hub.latestBatch }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .onTapGesture { handleClick() }
            .onAppear { hub.beginRefreshing() }
            .onDisappear { hub.endRefreshing() }
            .onChange(of: batch?.finished) { _, finished in
                scheduleDismiss(finished: finished == true)
            }
            .help(batch?.statusLine ?? device.map { "Drop to send to \(hub.label(for: $0))" } ?? (hub.problem ?? "No hub devices online"))
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            vm.dropZoneTargeting
                                ? Color.notchHighlight.opacity(0.9)
                                : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            VStack(spacing: 4) {
                badge
                labels
            }
            .padding(10)

            if isProcessing || hub.isPickerOpen {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Pieces

    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(vm.dropZoneTargeting ? 0.11 : 0.09))
                .frame(width: 44, height: 44)
            if let batch {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                    .frame(width: 44, height: 44)
                Circle()
                    .trim(from: 0, to: max(0.02, batch.fraction))
                    .stroke(ringColor(batch), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: 44)
                    .animation(.easeOut(duration: 0.4), value: batch.fraction)
            }
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(vm.dropZoneTargeting ? Color.notchHighlight : Color.gray)
                .scaleEffect(vm.dropZoneTargeting ? 1.06 : 1.0)
                .animation(.spring(response: 0.36, dampingFraction: 0.7), value: vm.dropZoneTargeting)
        }
    }

    private var iconName: String {
        if let batch, batch.finished {
            return batch.failed.isEmpty && !batch.helperOutdated ? "hub.check" : "hub.warning"
        }
        if let batch, let d = hub.devices.first(where: { $0.id == batch.deviceID }) { return d.iconName }
        return device?.iconName ?? "hub.offline"
    }

    private var icon: some View {
        Image(iconName).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
    }

    @ViewBuilder
    private var labels: some View {
        if let batch {
            let parts = batch.statusParts
            Text(parts.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail = parts.detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            if !batch.finished {
                smallButton("Cancel") { hub.cancel(batch.id) }
            } else if batch.canRetry {
                smallButton("Retry") { hub.retry(batch.id) }
            }
        } else if let device {
            Text(hub.label(for: device))
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(hub.problem == nil ? "No devices online" : "Hub helper is off")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if showSystemShareMenu {
                Text("Drop for More…")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .foregroundColor(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private func ringColor(_ batch: HubSendBatch) -> Color {
        if batch.finished, !batch.failed.isEmpty || batch.helperOutdated { return .orange }
        return Color.notchHighlight
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        let items = await hub.items(from: providers)
        guard !items.isEmpty else { return }
        if device != nil {
            hub.send(items)
        } else if showSystemShareMenu {
            hub.showSystemShareMenu(HubSendService.shareObjects(items), from: hostView)
        }
    }

    private func handleClick() {
        if let batch, batch.finished {
            dismissTask?.cancel()
            hub.dismiss(batch.id)
            return
        }
        guard let hostView else { return }
        let target = device
        let menu = HubSendMenu.make(
            service: hub,
            selected: target?.id,
            includeMore: showSystemShareMenu,
            onDevice: { picked in Defaults[.hubSendDevice] = picked.id },
            onSendFiles: target.map { target in
                {
                    hub.chooseFiles(title: "Send to \(hub.label(for: target))") { urls in
                        hub.send(urls.map { .file($0, shelfItemID: nil) }, to: target)
                    }
                }
            },
            onMore: {
                hub.chooseFiles(title: "Share") { urls in
                    hub.showSystemShareMenu(urls, from: hostView)
                }
            }
        )
        let y = hostView.isFlipped ? hostView.bounds.height : 0
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: hostView)
    }

    /// A good result goes after a few seconds; a failure stays until clicked or retried.
    private func scheduleDismiss(finished: Bool) {
        dismissTask?.cancel()
        guard finished, let batch, batch.failed.isEmpty, !batch.helperOutdated else { return }
        let id = batch.id
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            hub.dismiss(id)
        }
    }
}

// MARK: - The device menu (drop zone click, shelf item Share)

enum HubSendMenu {
    /// Devices (checkmark on `selected`), then the extras, then "More…" last.
    @MainActor
    static func make(service: HubSendService, selected: String?, includeMore: Bool,
                     onDevice: @escaping (HubSendDevice) -> Void,
                     onSendFiles: (() -> Void)? = nil,
                     onMore: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if service.targets.isEmpty {
            let none = NSMenuItem(title: service.problem ?? "No hub devices online", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for device in service.targets {
            let item = ClosureMenuItem(title: service.label(for: device)) { onDevice(device) }
            if let image = NSImage(named: device.iconName)?.copy() as? NSImage {
                image.isTemplate = true
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            }
            item.state = device.id == selected ? .on : .off
            menu.addItem(item)
        }
        if let onSendFiles {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Send files…", action: onSendFiles))
        }
        if includeMore {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "More…", action: onMore))
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() { handler() }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
