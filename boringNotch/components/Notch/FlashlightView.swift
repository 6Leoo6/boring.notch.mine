//
//  FlashlightView.swift
//  boringNotch
//

import SwiftUI

struct FlashlightView: View {
    @ObservedObject private var flashlight = FlashlightManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            // The light itself. Clicking it dismisses; the control cluster below swallows its
            // own clicks so the slider stays usable while lit.
            Rectangle()
                .fill(FlashlightManager.warmWhite)
                .clipShape(
                    RoundedRectangle(cornerRadius: 18 * (1 - flashlight.size), style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { flashlight.turnOff() }

            controlCluster
                .padding(.top, flashlight.clusterTopInset)
        }
        .ignoresSafeArea()
    }

    /// Dark on purpose: it is the only thing on screen that has to stay legible against a pane
    /// running at full output.
    private var controlCluster: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min")
                .font(.system(size: 11, weight: .semibold))

            Slider(value: $flashlight.size, in: 0...1) { editing in
                if !editing { flashlight.persistSize() }
            }
                .controlSize(.small)
                .frame(width: 190)
                .help("Pane size — a bigger lit area throws more light")

            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        .contentShape(Capsule())
        // Swallows clicks that land in the capsule but miss the slider, so fiddling with the
        // size control can never dismiss the thing you are adjusting.
        .onTapGesture {}
    }
}
