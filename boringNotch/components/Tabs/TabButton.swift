//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    /// `icon` names an image in the asset catalog (the hub icon set) instead of an SF Symbol.
    var asset: Bool = false
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            Group {
                if asset {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: icon)
                }
            }
                .padding(.horizontal, 15)
                .contentShape(Capsule())
        }
        .help(label)
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
