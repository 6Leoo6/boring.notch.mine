import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else {
            return .white
        }
    }

    private var showPowerIcon: Bool {
        (isCharging || isPluggedIn) && (isForNotification || Defaults[.showPowerStatusIcons])
    }

    private var fillHeight: CGFloat {
        max(1, (batteryWidth + 1) * 0.28)
    }

    // White fill + symmetric 8-directional 1.0pt black border = crisp 1px outline.
    // No explicit height — scaledToFit fills the ZStack height set by the battery SF Symbol.
    private func powerIconView(name: String) -> some View {
        let stroke = Color.black.opacity(0.6)
        return ZStack {
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x:  1.0, y:    0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x: -1.0, y:    0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x:    0, y:  1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x:    0, y: -1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x:  1.0, y:  1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x: -1.0, y:  1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x:  1.0, y: -1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(stroke).offset(x: -1.0, y: -1.0)
            Image(systemName: name).resizable().scaledToFit().foregroundColor(.white)
        }
    }

    var body: some View {
        Image(systemName: "battery.0")
            .resizable()
            .fontWeight(.thin)
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.white.opacity(0.5))
            .frame(width: batteryWidth + 1)
            // Fill bar — overlay is proposed exactly the battery image's rendered size.
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(batteryColor)
                    .frame(
                        width: max(0, CGFloat(levelBattery / 100.0) * (batteryWidth - 6)),
                        height: fillHeight
                    )
                    .padding(.leading, 2)
            }
            .overlay(alignment: .leading) {
                if showPowerIcon {
                    powerIconView(name: isCharging ? "bolt.fill" : "powerplug.portrait.fill")
                        .frame(width: batteryWidth - 2, alignment: .center)
                }
            }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var isInLowPowerMode: Bool
    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Max Capacity: \(Int(maxCapacity))%")
                    .font(.subheadline)
                    .fontWeight(.regular)
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if timeToFullCharge > 0 {
                    Label("Time to Full Charge: \(timeToFullCharge) min", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            Divider().background(Color.white)

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 280)
        .foregroundColor(.white)
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}

/// A view that displays the battery status and allows interaction to show detailed information.
struct BoringBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil

    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        Button(action: {
            withAnimation {
                showPopupMenu.toggle()
            }
        }) {
            HStack(spacing: 5) {
                if Defaults[.showBatteryPercentage] {
                    Text("\(Int32(levelBattery))%")
                        .font(.callout)
                        .foregroundStyle(.white)
                }
                BatteryView(
                    levelBattery: levelBattery,
                    isPluggedIn: isPluggedIn,
                    isCharging: isCharging,
                    isInLowPowerMode: isInLowPowerMode,
                    batteryWidth: batteryWidth,
                    isForNotification: isForNotification
                )
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                isInLowPowerMode: isInLowPowerMode,
                onDismiss: { 
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showPopupMenu) {
            vm.isBatteryPopoverActive = showPopupMenu
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showPopupMenu = false } }
        }
    }
}

#Preview("Battery States") {
    VStack(spacing: 12) {
        // Normal 80%
        HStack(spacing: 5) {
            Text("80%").font(.callout).foregroundStyle(.white)
            BatteryView(levelBattery: 80, isPluggedIn: false, isCharging: false, isInLowPowerMode: false, isForNotification: false)
        }
        // Charging 50%
        HStack(spacing: 5) {
            Text("50%").font(.callout).foregroundStyle(.white)
            BatteryView(levelBattery: 50, isPluggedIn: true, isCharging: true, isInLowPowerMode: false, isForNotification: false)
        }
        // Plugged in, not charging (100%)
        HStack(spacing: 5) {
            Text("100%").font(.callout).foregroundStyle(.white)
            BatteryView(levelBattery: 100, isPluggedIn: true, isCharging: false, isInLowPowerMode: false, isForNotification: false)
        }
        // Low battery
        HStack(spacing: 5) {
            Text("15%").font(.callout).foregroundStyle(.white)
            BatteryView(levelBattery: 15, isPluggedIn: false, isCharging: false, isInLowPowerMode: false, isForNotification: false)
        }
        // Low power mode
        HStack(spacing: 5) {
            Text("60%").font(.callout).foregroundStyle(.white)
            BatteryView(levelBattery: 60, isPluggedIn: false, isCharging: false, isInLowPowerMode: true, isForNotification: false)
        }
    }
    .padding(20)
    .background(Color.black)
}
