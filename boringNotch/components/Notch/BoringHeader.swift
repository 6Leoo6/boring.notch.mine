//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @ObservedObject var sleepManager = SleepManager.shared

    // An end time rather than a countdown: this sits in a 30pt slot inside the notch,
    // where a value that changes every second would re-layout the header continuously.
    private var keepAwakeHelp: String {
        guard sleepManager.isKeepingAwake else { return "Keep the Mac awake" }
        if let until = sleepManager.expiryDescription {
            return "Keeping the Mac awake until \(until)"
        }
        return "Keeping the Mac awake"
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 2) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showKeepAwake] {
                            Button(action: {
                                sleepManager.toggle()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: sleepManager.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                                            .foregroundColor(sleepManager.isKeepingAwake ? .effectiveAccent : .white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help(keepAwakeHelp)
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        // Ahead of the battery, so that a row too wide for the flank loses a
                        // pixel or two off the mirror or keep-awake button rather than off the
                        // recording timer, which is the one thing here that has to stay readable.
                        //
                        // Both keys: `showCaptureControls` hides the chrome, while
                        // `screenCaptureEnabled` is the feature switch the manager itself obeys —
                        // without it these buttons would still be here and would do nothing.
                        if Defaults[.showCaptureControls] && Defaults[.screenCaptureEnabled] {
                            CaptureControls()
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 22,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .background(Capsule().fill(.black))
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

/// Screenshot and screen-recording controls for the header's right-hand row.
///
/// The two at-rest buttons and the recording timer share one slot of the same width, so starting
/// or stopping a recording never re-flows the row. That matters more here than anywhere else in
/// the header: the notch splits the open panel into two fixed flanks, and this row has to live
/// inside the right one — roughly 197pt on a 14" MacBook Pro, of which the existing controls
/// already take about 145. A pill that grew on top of both buttons would push the row's leading
/// control under the physical notch, where it is simply invisible.
struct CaptureControls: View {
    @ObservedObject var captureManager = ScreenCaptureManager.shared

    /// Width of the two-button pair — 30 + 30 with the row's own 2pt gap — which the recording
    /// pill then adopts as its minimum.
    private static let slotWidth: CGFloat = 62

    private var isRecording: Bool {
        captureManager.isRecording
    }

    // Monospaced digits hold the pill at one width for a whole minute. The header lives in a
    // fixed-width notch, so a timer that re-measured on every tick would nudge the row each second.
    //
    // Past an hour it drops the seconds and counts `h:mm` instead. Not for readability — it is
    // what bounds the pill: `m:ss` would reach six characters at 100:00 and widen the row a
    // third time, and the right flank has nothing left to give. This way the widest the pill
    // ever gets is "59:59", and an hour-long recording is back to the width of "0:07".
    private var elapsed: String {
        let seconds = max(captureManager.recordingSeconds, 0)
        if seconds < 3600 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return String(format: "%dh%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    var body: some View {
        if captureManager.canCapture {
            Group {
                if isRecording {
                    recordingPill
                } else {
                    HStack(spacing: 2) {
                        startRecordingControl
                        screenshotControl
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: isRecording)
        }
    }

    private var recordingPill: some View {
        Button(action: {
            captureManager.stopRecording()
        }) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .imageScale(.small)
                Text(elapsed)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(minWidth: Self.slotWidth, minHeight: 30)
            .background(Capsule().fill(Color.red))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help("Stop the screen recording")
    }

    private var startRecordingControl: some View {
        Button(action: {
            captureManager.startRecording()
        }) {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "record.circle")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help("Record a selected area")
    }

    private var screenshotControl: some View {
        Button(action: {
            captureManager.takeScreenshot()
        }) {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "camera")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help("Screenshot a selected area")
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
