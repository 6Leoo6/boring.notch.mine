//
//  HubSendTileRing.swift
//  boringNotch
//
//  The ring on a shelf tile while that item is being sent to another device (hub D-178).
//  The drop zone carries the line and Cancel; the tile only shows how far it is.
//

import SwiftUI

struct HubSendTileRing: View {
    let itemID: UUID
    let tileSize: CGFloat
    @ObservedObject private var hub = HubSendService.shared

    var body: some View {
        if let entry = hub.runningEntry(forShelfItem: itemID) {
            ZStack {
                RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(0.35))
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, entry.fraction))
                        .stroke(Color.notchHighlight, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: entry.fraction)
                }
                .frame(width: tileSize * 0.45, height: tileSize * 0.45)
            }
            .frame(width: tileSize, height: tileSize)
            .transition(.opacity)
        }
    }
}
