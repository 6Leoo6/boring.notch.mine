//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

/// Regions that own scrolling along an axis outright, so a pan over them is never
/// reinterpreted as a tab switch or an open/close gesture. Geometry alone is not enough: a
/// list scrolled to its end, or one whose items happen to fit, reports no room to scroll
/// while the user is plainly still scrolling it.
@MainActor
final class ScrollOwners {
    static let shared = ScrollOwners()
    private var regions: [UUID: Axis] = [:]

    func owns(_ axis: Axis) -> Bool { regions.values.contains(axis) }

    func setInside(_ inside: Bool, id: UUID, axis: Axis) {
        if inside {
            regions[id] = axis
        } else {
            regions[id] = nil
        }
    }

    func forget(_ id: UUID) {
        regions[id] = nil
    }
}

private struct ScrollOwnerModifier: ViewModifier {
    let axis: Axis
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { ScrollOwners.shared.setInside($0, id: id, axis: axis) }
            .onDisappear { ScrollOwners.shared.forget(id) }
            // The panel can switch axis under a stationary cursor when it expands into a grid
            .onChange(of: axis) { _, newAxis in
                ScrollOwners.shared.setInside(true, id: id, axis: newAxis)
            }
    }
}

extension View {
    /// Marks a scrolling region that owns its gestures outright: while the pointer is inside
    /// it, pan gestures along `axis` are suppressed. The other axis is unaffected.
    func ownsScrolling(axis: Axis) -> some View {
        modifier(ScrollOwnerModifier(axis: axis))
    }

    func panGesture(direction: PanDirection, threshold: CGFloat = 4, action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
        self
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !ScrollOwners.shared.owns(direction.isHorizontal ? .horizontal : .vertical) else { return }
                        let s = direction.signed(from: value.translation)
                        guard s > 0, s.magnitude >= threshold else { return }
                        action(s.magnitude, .changed)
                    }
                    .onEnded { _ in action(0, .ended) }
            )
            .background(ScrollMonitor(direction: direction, threshold: threshold, action: action))
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, action: action) 
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
        private var claimedByNestedScroll = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.action = action
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                claimedByNestedScroll = false
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self = self, let view, event.window === view.window else { return event }
                self.handleScroll(event, in: view)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            accumulated = 0
            active = false
            claimedByNestedScroll = false
            endTask?.cancel()
            endTask = nil
        }

        private func handleScroll(_ event: NSEvent, in view: NSView) {
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                claimedByNestedScroll = false
                endTask?.cancel()
                endTask = nil
                return
            }

            // Ignore momentum-phase events — physics deceleration after finger lift should
            // never re-trigger an intent gesture.
            guard event.momentumPhase.isEmpty else { return }

            // A scroll that starts inside an excluded region, or over a nested horizontal
            // scroll view, belongs to that list and not to us. Re-evaluate only while the
            // gesture is still forming; once it has been claimed either way the latch holds
            // until the gesture ends, so drifting off the strip mid-scroll cannot hand the
            // rest of the swipe back to the tab switcher.
            if !active {
                claimedByNestedScroll = ScrollOwners.shared.owns(direction.isHorizontal ? .horizontal : .vertical)
                    || (direction.isHorizontal && Self.isOverHorizontalScrollView(event, in: view))
            }
            guard !claimedByNestedScroll else { return }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Natural scrolling inverts horizontal deltas, so normalise them here: `.left`
            // then always means a physical swipe to the left, whatever the system setting.
            let deltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let raw = direction.signed(deltaX: deltaX, deltaY: event.scrollingDeltaY)
            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }

        private static func isOverHorizontalScrollView(_ event: NSEvent, in view: NSView) -> Bool {
            guard let contentView = view.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow) else { return false }

            var candidate: NSView? = hit
            while let current = candidate {
                if let scrollView = current as? NSScrollView, scrollView.scrollsHorizontally {
                    return true
                }
                candidate = current.superview
            }
            return false
        }
    }
}

private extension NSScrollView {
    /// True only when the document is genuinely wider than the visible clip area — a
    /// vertical-only list must not swallow horizontal tab swipes.
    var scrollsHorizontally: Bool {
        guard let documentView else { return false }
        return documentView.frame.width - contentView.bounds.width > 1
    }
}
