//
//  EmptyState.swift
//
// Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import SwiftUI

struct EmptyStateView: View {
    var message: String
    @State private var isVisible = true
    
    var body: some View {
        HStack {
            MinimalFaceFeatures(
                height: 70, width: 80)
            Text(message)
                .font(.system(size:14))
                .foregroundColor(.gray)
        }.transition(.blurReplace.animation(.spring(.bouncy(duration: 0.3)))) // Smooth animation
    }
}

/// The shared "nothing here yet" state for the notch's shelf and clipboard panels, so the
/// two differ only in their icon and wording.
struct NotchEmptyState: View {
    let icon: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .symbolVariant(.fill)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)

            Text(message)
                .foregroundStyle(.gray)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.blurReplace.animation(.spring(.bouncy(duration: 0.3))))
    }
}

#Preview {
    EmptyStateView(message: "Play some music babies")
}

#Preview("Notch panels") {
    HStack(spacing: 0) {
        NotchEmptyState(icon: "tray.and.arrow.down", message: "Drop files here")
        NotchEmptyState(icon: "clipboard", message: "Nothing copied yet")
    }
    .frame(width: 440, height: 90)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
