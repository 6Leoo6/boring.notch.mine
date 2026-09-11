//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var closeWatchTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero
    @State private var glowPulse: Bool = false
    @State private var tabSwitchCooldown: Bool = false
    @State private var tabSwitchTask: Task<Void, Never>?

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Master gate for every coloured element in the player UI
    @Default(.playerColorTinting) var playerColorTinting

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    // Total extra island height requested by whatever is expanded below the tabs
    private var islandExpansion: CGFloat {
        vm.notchState == .open ? coordinator.islandExpansion : 0
    }

    // The part of it that stays empty island surface rather than growing the tab content
    private var clipboardPreviewBand: CGFloat {
        vm.notchState == .open ? coordinator.clipboardPreviewBand : 0
    }

    // White unless the player tint is on, per the same helper the rest of the player uses
    private var pinGlowColor: Color {
        playerColorTinting ? .playerTint(from: musicManager.avgColor, fallback: .white) : .white
    }

    // One pulse drives both glows — the pinned outline and the closed island's artwork wash.
    // They can never be on screen together (closing clears the pin), so a single repeating
    // animation and a single piece of state serve both.
    private var isGlowPulsing: Bool {
        (vm.isPinned || closedArtGlowIsLive) && musicManager.isPlaying
    }

    // Breathing range for the pinned glow, deliberately left alone as the glow underneath it
    // got brighter. The crest:trough ratio is exactly 1.6, and it is the ratio and not the
    // absolute level that decides how much the pulse pulls the eye — which is what "narrow on
    // purpose" was protecting here. Held across two rounds of strengthening: drawn light
    // breathes 1.59x on the old stack and 1.56x on this one, so the pulse is fractionally
    // gentler in relative terms even though its absolute swing has nearly doubled.
    private var pinGlowOpacity: Double {
        guard vm.isPinned else { return 0 }
        return glowPulse ? 0.92 : 0.575
    }

    /// Mirrors the branch that draws `MusicLiveActivity`, so the pulse is never started for a
    /// glow that is not on screen — this animation would otherwise run for as long as the notch
    /// is closed, which is nearly always. Deliberately a copy of that predicate rather than a
    /// refactor of it: the same test is spelled out inline in `computedChinWidth` too, and
    /// rewiring all three would be a layout change dressed up as a glow change.
    private var closedArtGlowIsLive: Bool {
        guard Defaults[.lightingEffect], vm.notchState == .closed, !vm.hideOnClosed else { return false }
        guard coordinator.musicLiveActivityEnabled else { return false }
        guard musicManager.isPlaying || !musicManager.isPlayerIdle else { return false }
        return !coordinator.expandingView.show || coordinator.expandingView.type == .music
    }

    // Shallower than the pinned outline's breath: this one sits under the only bright thing on
    // the closed island and must not compete with it.
    private var closedArtGlowOpacity: Double {
        glowPulse ? 0.42 : 0.26
    }

    // Drift, not travel. A couple of points, so the glow reads as alive without the artwork
    // looking like it is sitting on something loose.
    private var closedArtGlowOffset: CGSize {
        glowPulse ? CGSize(width: 1.5, height: -1) : CGSize(width: -1.5, height: 1)
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()

        // #53 diagnostic, inert unless BN_HOVER_DEBUG is set. The island's root transform and
        // the width its subtree is laid out at, published so they appear on the same line as a
        // clipboard hover hand-off. A plain static assignment, not SwiftUI state, so it cannot
        // invalidate anything. Delete with the rest of the #53 instrumentation.
        // A `let` binding rather than a bare statement: this sits inside a ViewBuilder, where a
        // loose `if` is parsed as a view and fails to compile.
#if BN_DIAG
        let _: Void = {
            ClipboardBisect.announce()
            guard ClipboardHoverOwner.handoffLoggingEnabled else { return }
            ClipboardHoverOwner.islandDiagnostics = String(
                format: "gScale %.4f  gProg %.3f  layoutW %.1f",
                Double(gestureScale), Double(gestureProgress), Double(windowSize.width)
            )
        }()
#endif

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    // Padding rather than a taller frame, so the preview band is empty island
                    // surface instead of the tab content being stretched down into it. The
                    // grid expansion is deliberately absent: there the panel itself must grow.
                    .padding(.bottom, clipboardPreviewBand)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .overlay {
                        // Soft bloom on the island's own outline while pinned, in three passes:
                        // a wide bloom, a tight core, and a hairline. Each owns one part of the
                        // look, which is what lets the glow get brighter without getting harder.
                        //
                        // Group opacity is NOT the dial here, and neither is spread on its own.
                        // Raising `pinGlowOpacity` brightens the whole ribbon evenly into a hard
                        // border and spends the headroom the pulse rides on. Spread alone smears
                        // the same energy wider, so the light near the outline actually drops.
                        // Measured, the group's peak was pinned by the hairline alone — sweeping
                        // it 0 -> 1 moved peak 0.2118 -> 0.9294 while drawn light moved 7%, which
                        // is the signature of a border, not a glow. So brightness comes from the
                        // core pass, which raises light and peak together at fixed group opacity.
                        //
                        // The radius is not bounded by the window: the clipShape below removes
                        // everything outward whatever the radius, and the window's own edge
                        // columns measure 0.0000 at every radius tried.
                        currentNotchShape
                            .stroke(pinGlowColor, lineWidth: 5)
                            .blur(radius: 10)
                            // Bloom inward: the island spans the window's full width, so an
                            // outward glow would be sliced off at the left and right edges
                            .clipShape(currentNotchShape)
                            .overlay {
                                // The core. Blurred tightly enough to stay a hot band within
                                // ~4pt of the outline rather than joining the wide bloom, which
                                // is what reads as light with a source instead of as fog. Needs
                                // the same inward clip as the bloom — its blur bleeds outward too.
                                currentNotchShape
                                    .stroke(pinGlowColor.opacity(0.85), lineWidth: 3)
                                    .blur(radius: 4)
                                    .clipShape(currentNotchShape)
                            }
                            .overlay {
                                // Keeps the outline a line. Raised with the core behind it: at
                                // 0.5 the line-to-just-inside contrast fell from 1.96x to 1.39x
                                // and the edge started dissolving into the bloom, which is the
                                // exact failure this pass exists to prevent. 0.7 restores 1.53x
                                // and costs 2% in drawn light, because a 0.5pt line is all edge.
                                currentNotchShape.stroke(pinGlowColor.opacity(0.7), lineWidth: 0.5)
                            }
                            // The island's top edge sits flush against the screen, so a glow
                            // there reads as a seam rather than a bloom. Fade it out rather
                            // than cutting it, which would leave a visible hard edge.
                            //
                            // The second `.clear` stop holds the top of the island at exactly
                            // zero. A plain two-stop ramp is only zero at the boundary itself,
                            // so the topmost pixel row samples just inside it and quantises to
                            // 1/255. Its location is a FRACTION of height, so a short island —
                            // what the close animation passes through — gets a proportionally
                            // tiny flat zone: at 0.02 the shipped glow already leaked 0.0275 at
                            // 16pt and 0.1020 at 12pt, and this brighter one leaked more. 0.05
                            // holds every height down to 16pt at 0.0000 for 2% of the light.
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.05),
                                        .init(color: .black, location: 0.28),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .opacity(pinGlowOpacity)
                            .animation(.easeInOut(duration: 0.28), value: vm.isPinned)
                            .allowsHitTesting(false)
                            .onChange(of: isGlowPulsing) { _, pulsing in
                                setGlowPulse(pulsing)
                            }
                            .onAppear {
                                setGlowPulse(isGlowPulsing)
                            }
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height + islandExpansion : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    // Double click pins; interactive children consume their own taps, so this
                    // only ever fires on the island's empty surface
                    .onTapGesture(count: 2) {
                        guard vm.notchState == .open else { return }
                        vm.togglePinned()
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.enableGestures] && Defaults[.boringShelf]) { view in
                        view
                            .panGesture(direction: .left) { translation, _ in
                                handleLeftGesture(translation: translation)
                            }
                            .panGesture(direction: .right) { translation, _ in
                                handleRightGesture(translation: translation)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if autoCloseIsAllowed {
                            scheduleAutoClose()
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        guard newState == .closed else { return }
                        closeWatchTask?.cancel()
                        // Every close path funnels through this transition, so clearing the
                        // preview here is what lets the window shrink back to its real height.
                        coordinator.clipboardPreviewEntry = nil
                        if isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    // Unpinning, or dismissing a modal, is the moment the auto-close has to come
                    // back: the hover-exit that would normally arm it already fired and stood
                    // down while the guard was up, and no further hover event is owed to us.
                    // A modal hands the cursor back off the island, so the one-shot arm is enough
                    // there. An unpin cannot: it is a double-click ON the island, so the cursor is
                    // still on it and only the watchdog can carry the close.
                    .onChange(of: vm.blocksAutoClose) { _, blocks in
                        guard !blocks else {
                            closeWatchTask?.cancel()
                            return
                        }
                        if autoCloseIsAllowed {
                            scheduleAutoClose()
                        } else {
                            armCloseWatchdog()
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .onChange(of: vm.isPinned) { _, pinned in
                        playPinHaptic(pinned)
                    }
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }

        }
        .padding(.bottom, 8)
        // Fill the window rather than tracking the island's animating height. The window is
        // resized to its expanded size in one step, so a root that is briefly shorter than the
        // window gets centred in it — which drops the whole island and slides it back up.
        .frame(maxWidth: windowSize.width, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .background(
            NotchWindowBinder { window in
                // Only claimed when nothing else owns it. Nothing in the app sets a delegate on
                // the notch panel today, and silently displacing a future one would be worse
                // than losing the sheet fix.
                if window.delegate == nil {
                    window.delegate = NotchSheetPositioner.shared
                }
            }
        )
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen(trigger: .system)
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
        // Any hand-back of island height needs a grace window, whoever triggers it. Keyed on the
        // height rather than on the tab because the height IS the hazard: `isMouseHovering`
        // measures against `notchSize.height + islandExpansion`, and with the notch open the
        // first term is fixed — so the model's idea of where the island is can only go stale
        // when `islandExpansion` moves. A tab switch that hands back the grid (the coordinator's
        // `currentView.didSet`, which has no `vm` to arm this itself) lands here; a tab switch
        // that changes no height has nothing to go stale and needs nothing.
        //
        // Shrink only, and only while open. Growth cannot strand the cursor outside a rect that
        // is getting bigger, and arming this as the island CLOSES would leave the grace flag set
        // for 800ms into an island that has already gone — which is the machinery #34 and #38
        // were about.
        .onChange(of: islandExpansion) { previous, current in
            guard vm.notchState == .open, current < previous else { return }
            vm.beginCloseGrace()
        }
        .onChange(of: coordinator.clipboardPreviewEntry == nil) { wasNil, isNil in
            // When the preview is dismissed while the notch stays open, give the user extra
            // time to move their cursor back onto the shrunken island before it auto-closes.
            // A preview cleared as part of closing needs no such grace period.
            if isNil && !wasNil && vm.notchState == .open {
                vm.beginCloseGrace()
                // The island just shrank out from under the cursor, so the hover-exit that
                // follows is not the user leaving. Dropping that exit outright, though, leaves
                // nothing at all armed to close the island: re-arm it on the grace delay, and
                // let the fire-time cursor check decide whether the user really went.
                scheduleAutoClose()
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? .playerTint(from: musicManager.avgColor, fallback: .gray) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .overlay(alignment: .top) {
            if vm.notchState == .open, let entry = coordinator.clipboardPreviewEntry {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 0.5)
                        .padding(.horizontal, 4)
                    ClipboardPreviewPanel(entry: entry) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            coordinator.clipboardPreviewEntry = nil
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: clipboardPreviewHeight)
                .background(.black)
                .padding(.top, vm.notchSize.height)
                .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let artSide = max(0, vm.effectiveClosedNotchHeight - 12)

        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(width: artSide, height: artSide)
                .background {
                    if Defaults[.lightingEffect] {
                        closedArtGlow(side: artSide)
                    }
                }

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: playerColorTinting && Defaults[.coloredSpectrogram]
                                    ? .playerTint(from: musicManager.avgColor, fallback: .gray)
                                    : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    playerColorTinting && Defaults[.coloredSpectrogram]
                                        ? Color.playerTint(from: musicManager.avgColor, fallback: .gray)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            playerColorTinting && Defaults[.coloredSpectrogram]
                                ? Color.playerTint(from: musicManager.avgColor, fallback: .gray).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    /// Soft wash behind the closed island's artwork.
    ///
    /// A tint gradient, not a blurred copy of the cover. The open notch's `lightingEffect` takes
    /// its colour from the artwork's own pixels, which works over a 90pt cover but not here: a
    /// dark album would produce a black glow on a black island. `playerTint` has a brightness
    /// floor, so every track gets a wash that is actually visible. The trade is that it carries
    /// the album's hue rather than its pixels, and holds still through a track instead of
    /// shimmering with the art — for a 20pt thumbnail, being visible wins.
    ///
    /// No blur and no blend mode, deliberately. The gradient's own falloff IS the softness, so
    /// nothing has to be rasterised per frame, and `.blendMode` is the one compositing feature
    /// this project has already been bitten by on the real CoreAnimation path.
    ///
    /// Clipping is handled by geometry rather than by masks, which is what keeps it free. A halo
    /// of 1.9x the artwork reaches 0.45x past its edge, staying inside the 14pt inset the closed
    /// layout already has, so it fades to nothing before the island's left edge instead of being
    /// sliced off there — measured at 0.000 luminance on the edge column.
    ///
    /// Vertically there are only 6pt of island either side of the artwork, and the top edge sits
    /// flush against the screen, where a glow reads as a seam rather than a bloom. Squashing the
    /// halo to 0.7 brings its falloff inside those 6pt: measured, an unsquashed halo left 0.09
    /// luminance along the top edge and this leaves none. Scaling rather than masking keeps the
    /// falloff smooth (a shape cut would replace the seam with a hard edge) and costs a transform
    /// instead of an offscreen pass. It also suits the island, which is wide and short.
    @ViewBuilder
    private func closedArtGlow(side: CGFloat) -> some View {
        let halo = side * 1.9

        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: pinGlowColor.opacity(0.9), location: 0),
                        // Placed at the artwork's own edge: everything inside it is hidden
                        // behind the art, so this stop is what the eye actually reads as glow.
                        .init(color: pinGlowColor.opacity(0.55), location: 0.55),
                        .init(color: .clear, location: 1),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: halo / 2
                )
            )
            .frame(width: halo, height: halo)
            .scaleEffect(x: 1, y: 0.7, anchor: .center)
            .offset(x: closedArtGlowOffset.width, y: closedArtGlowOffset.height)
            .opacity(closedArtGlowOpacity)
            .allowsHitTesting(false)
    }

    /// Starts or stops the pinned glow's breathing. `repeatForever` has to be applied at the
    /// moment the value flips, so this cannot be expressed as an `.animation(_:value:)`.
    private func setGlowPulse(_ pulsing: Bool) {
        if pulsing {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                glowPulse = false
            }
        }
    }

    /// macOS exposes only three haptic patterns (`generic`, `alignment`, `levelChange`) — the
    /// weighted `impact` styles are iOS-only and produce nothing here, which is why the pin
    /// used to feel like nothing at all. Lock and unlock are therefore distinguished by
    /// RHYTHM as much as pattern: locking is a firm double beat, unlocking a single soft tick.
    private func playPinHaptic(_ pinned: Bool) {
        guard Defaults[.enableHaptics] else { return }
        let performer = NSHapticFeedbackManager.defaultPerformer

        guard pinned else {
            performer.perform(.alignment, performanceTime: .now)
            return
        }

        performer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            performer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// Defaults to `.pointer` because every caller here is the cursor acting on the island —
    /// a hover, a tap, a swipe. The drop path passes `.system`: a drag carries its own
    /// meaning for ⌥ (the Finder's copy modifier) and must not be read as a tab request.
    private func doOpen(trigger: NotchOpenTrigger = .pointer) {
        // Fire on the real closed -> open transition, so the haptic lands with the
        // opening animation rather than when the cursor merely enters the hover zone.
        if vm.notchState == .closed && Defaults[.enableHaptics] {
            haptics.toggle()
        }
        withAnimation(animationSpring) {
            vm.open(trigger: trigger)
        }
    }

    // MARK: - Hover Management

    /// `isHovering` is a cache of hover EVENTS, and an event can go missing: a pending
    /// hover-exit gets cancelled whenever the island resizes under the cursor, which leaves the
    /// cache stuck on `true` with no exit still owed. Every auto-close path then reads the
    /// island as hovered and stands down permanently. The pointer's actual position cannot go
    /// stale, so it decides; the cache is only the fallback for a screen we cannot measure.
    private var cursorHasLeftIsland: Bool {
        vm.isMouseHovering().map { !$0 } ?? !isHovering
    }

    /// The standing conditions for arming an auto-close, as one named value rather than a
    /// compound test at each call site: the modifier chains in this file are long enough that
    /// one more inline `&&` puts the type-checker over its budget.
    private var autoCloseIsAllowed: Bool {
        guard vm.notchState == .open else { return false }
        guard !vm.blocksAutoClose else { return false }
        guard !SharingStateManager.shared.preventNotchClose else { return false }
        return cursorHasLeftIsland
    }

    /// Carries the close for a guard that dropped while the cursor was still on the island.
    ///
    /// The one-shot re-arm cannot: it asks `autoCloseIsAllowed`, which requires the cursor to
    /// have left, and an unpin is a double-click ON the island — so at that instant the answer is
    /// false by construction and the arm is a no-op. All that was left holding the close was the
    /// next hover-exit event, and hover-exits go missing here: a window resize under a stationary
    /// cursor emits its own exit (measured), which arms a close that bails because the cursor is
    /// still inside, spending the event for nothing. Nothing then re-checks, and the island stays
    /// open for good.
    ///
    /// Polling instead of waiting on that event. One wake every 300ms, and only while the island
    /// is open AND unguarded — it returns the moment either stops holding, which for a notch that
    /// is closed almost all the time means it is almost never running.
    private func armCloseWatchdog() {
        closeWatchTask?.cancel()
        closeWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                guard self.vm.notchState == .open, !self.vm.blocksAutoClose else { return }

                // A grace window means the island just moved out from under the cursor, so the
                // rect `cursorHasLeftIsland` measures against and the island as DRAWN disagree
                // for as long as it is animating. The event path can afford to merely stretch
                // its delay for that: it gets one shot, and by the time it fires the geometry
                // has settled. A repeating poll cannot — it re-asks every 300ms, so it only has
                // to catch one tick inside the disagreement to close the notch under the user.
                // Suppress instead, and let the tick after the grace decide on settled geometry.
                if self.vm.closeGraceActive { continue }

                // Hands back to the single arming path, so the delay and the fire-time
                // re-checks stay in one place.
                if self.autoCloseIsAllowed {
                    self.scheduleAutoClose()
                    return
                }
            }
        }
    }

    /// The one place an auto-close is armed. Everything is re-checked when the timer fires
    /// rather than trusted from when it was armed, so a stale flag can never strand the island
    /// open and a cursor that came back can never have it close underneath.
    private func scheduleAutoClose() {
        let delayMs: Int = vm.closeGraceActive ? 600 : 100
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.cursorHasLeftIsland else { return }

                withAnimation(self.animationSpring) {
                    self.isHovering = false
                }

                guard self.vm.notchState == .open,
                      !self.vm.blocksAutoClose,
                      !SharingStateManager.shared.preventNotchClose else { return }

                self.vm.close()
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            scheduleAutoClose()
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar && !tabSwitchCooldown else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func cycleTab(forward: Bool) {
        if Defaults[.enableHaptics] { haptics.toggle() }
        let tabs: [NotchViews] = [.home, .shelf]
        guard let idx = tabs.firstIndex(of: coordinator.currentView) else { return }
        let next = forward
            ? (idx + 1) % tabs.count
            : (idx - 1 + tabs.count) % tabs.count
        withAnimation(.smooth(duration: 0.35)) {
            coordinator.currentView = tabs[next]
        }
    }

    private func armTabCooldown() {
        tabSwitchCooldown = true
        tabSwitchTask?.cancel()
        tabSwitchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            tabSwitchCooldown = false
        }
    }

    // Fixed threshold for horizontal tab switching — independent of the open/close
    // gesture sensitivity so users can set a high open/close threshold without
    // making tab switching require an unreasonably large swipe.
    private let tabSwipeThreshold: CGFloat = 60

    // panGesture normalises for natural scrolling, so .left/.right are always the
    // physical swipe direction: left = forward, right = backward, as in Safari.
    private func handleLeftGesture(translation: CGFloat) {
        guard vm.notchState == .open, !tabSwitchCooldown,
              translation > tabSwipeThreshold else { return }
        armTabCooldown()
        cycleTab(forward: true)
    }

    private func handleRightGesture(translation: CGFloat) {
        guard vm.notchState == .open, !tabSwitchCooldown,
              translation > tabSwipeThreshold else { return }
        armTabCooldown()
        cycleTab(forward: false)
    }
}

/// Keeps an AppKit sheet from dragging the island down with it.
///
/// SwiftUI's `.alert` on macOS is not a free-floating window: it is presented as a SHEET on the
/// hosting window. AppKit anchors a sheet to its parent's top edge, then refuses to let the
/// sheet overlap the menu bar — and it makes room by moving the PARENT down by the menu-bar
/// height. The island's top edge is flush with the screen, so every alert raised from inside the
/// notch shoved the whole island down (33pt on a 1470×956 display) and snapped it back on
/// dismissal. Measured under `NSApp.run()`, sampling the panel frame every 8ms: -33pt with no
/// delegate, 0pt with this one, and the sheet itself lands on exactly the same screen pixels
/// either way — placing the sheet that low ourselves simply removes AppKit's reason to move.
///
/// Stateless, so one instance can serve every notch window and there is no delegate to outlive.
private final class NotchSheetPositioner: NSObject, NSWindowDelegate {
    static let shared = NotchSheetPositioner()

    func window(_ window: NSWindow, willPositionSheet _: NSWindow, using rect: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return rect }
        // `rect` is in the parent's coordinates; only the part poking above the menu bar matters.
        let overhang = (window.frame.origin.y + rect.maxY) - screen.visibleFrame.maxY
        guard overhang > 0 else { return rect }
        return rect.offsetBy(dx: 0, dy: -overhang)
    }
}

/// Hands the hosting window to a closure once there is one. `viewDidMoveToWindow` rather than a
/// dispatch from `makeNSView`, so the window is claimed on the first pass instead of a frame later.
private struct NotchWindowBinder: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context _: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ probe: Probe, context _: Context) {
        probe.onWindow = onWindow
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
