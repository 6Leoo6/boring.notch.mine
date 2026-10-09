import AppKit
import Defaults
import SwiftUI

/// The battery glyph the macOS menu bar draws, reproduced from the same SF Symbol.
///
/// `battery.100percent` at `.light` weight is the menu bar's shape. Under
/// `.symbolRenderingMode(.palette)` its first layer is the fill bar and its second the
/// outline plus terminal nub, and `.resizable()` lays the ink out exactly on the proposed
/// frame — so the outline needs no hand-measured geometry at all.
///
/// The level is the fill layer intersected with a copy of itself shifted left by the unused
/// part of the track. Both ends of the bar therefore keep Apple's own rounding, and the only
/// measured constant left is how wide that track is.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    /// Ink width of the glyph in points; the height follows from `aspectRatio`.
    var batteryWidth: CGFloat = BatteryView.menuBarWidth
    var isForNotification: Bool

    /// Ink width of the menu bar's battery, measured off a 2x screenshot: 51 px.
    static let menuBarWidth: CGFloat = 25.5
    /// Layout aspect of `battery.100percent`; its ink fills that box exactly.
    static let aspectRatio: CGFloat = 19.0 / 9.0
    /// Layout aspect of `battery.100percent.bolt`, whose bolt overhangs the outline.
    private static let chargingAspectRatio: CGFloat = 19.0 / 12.0

    private static let symbolName = "battery.100percent"
    private static let chargingSymbolName = "battery.100percent.bolt"
    /// Width of the fill bar at 100%, as a fraction of the ink width.
    private static let trackWidthFraction: CGFloat = 0.73971
    /// Plug height relative to the outline.
    ///
    /// Was 1.065, measured off the reference, and at that size the plug's top border read as
    /// DUPLICATED (#59). The prongs cleared the outline by `(1.065 - 1)/2 · height` = 0.393pt
    /// against an outline stroke measured at 1.188pt — a third of a stroke, 0.8 of a device
    /// pixel at 2x. Two near-parallel lines that close together do not read as a tip standing
    /// proud of a border; they read as one thick border drawn twice.
    ///
    /// Derived instead of eyeballed: clear the border by a FULL stroke, so the two can never
    /// merge at any size or scale factor. `1 + 2 · strokeFraction`, with the stroke measured
    /// at 0.09836 · height (1.188pt on a 12.079pt glyph, read off a 16x render).
    private static let outlineStrokeFraction: CGFloat = 0.09836
    private static let plugHeightFraction: CGFloat = 1 + 2 * BatteryView.outlineStrokeFraction
    /// How far the knockout copy is dilated past the glyph. Scaling about the ink's own centre
    /// gives each flank `(scale - 1)` times the ink's half-width (0.15197 · `batteryWidth`),
    /// so this is the 0.0348 · `batteryWidth` gap the reference shows, measured off drawn pixels.
    private static let plugKnockoutScale: CGFloat = 1.2289
    /// Centre of the outline's body, excluding the terminal nub — where Apple puts the bolt.
    private static let bodyCentreFraction: CGFloat = 0.45221

    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else {
            return .white
        }
    }

    private var shellColor: Color {
        .white.opacity(0.5)
    }

    private var showPowerIcon: Bool {
        (isCharging || isPluggedIn) && (isForNotification || Defaults[.showPowerStatusIcons])
    }

    private var height: CGFloat {
        batteryWidth / Self.aspectRatio
    }

    /// One palette layer set of a battery symbol. The frame is fully specified because
    /// `.overlay`/`.background` propose the *outline's* height, which would otherwise shrink
    /// the taller charging symbol to fit.
    private func symbol(_ name: String, aspect: CGFloat,
                        _ primary: Color, _ secondary: Color, _ tertiary: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .fontWeight(.light)
            .symbolRenderingMode(.palette)
            .foregroundStyle(primary, secondary, tertiary)
            .frame(width: batteryWidth, height: batteryWidth / aspect)
    }

    private func battery(fill: Color, shell: Color) -> some View {
        symbol(Self.symbolName, aspect: Self.aspectRatio, fill, shell, .clear)
    }

    private func chargingBattery(bolt: Color, shell: Color, fill: Color) -> some View {
        symbol(Self.chargingSymbolName, aspect: Self.chargingAspectRatio, bolt, shell, fill)
    }

    private var plugGlyph: some View {
        Image(systemName: "powerplug.portrait.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(batteryColor)
            .frame(width: batteryWidth, height: height * Self.plugHeightFraction)
            .offset(x: (Self.bodyCentreFraction - 0.5) * batteryWidth)
    }

    /// The fill bar, clipped to `levelBattery`. When charging this uses Apple's charging
    /// composite, whose fill layer already has the bolt knocked out of it; for the
    /// plugged-in-but-not-charging plug the same gap is punched with a dilated copy.
    private var fillBar: some View {
        let level = CGFloat(min(max(levelBattery, 0), 100)) / 100
        return Group {
            if showPowerIcon && isCharging {
                chargingBattery(bolt: .clear, shell: .clear, fill: batteryColor)
            } else {
                battery(fill: batteryColor, shell: .clear)
            }
        }
        .mask {
            battery(fill: .white, shell: .clear)
                .offset(x: -batteryWidth * Self.trackWidthFraction * (1 - level))
        }
    }

    /// While charging the outline also comes from the charging composite, which carries
    /// Apple's gap in the outline where the bolt crosses it.
    private var outline: some View {
        Group {
            if showPowerIcon && isCharging {
                chargingBattery(bolt: .clear, shell: shellColor, fill: .clear)
            } else {
                battery(fill: .clear, shell: shellColor)
            }
        }
    }

    @ViewBuilder private var powerGlyph: some View {
        if showPowerIcon {
            if isCharging {
                chargingBattery(bolt: batteryColor, shell: .clear, fill: .clear)
            } else {
                plugGlyph
            }
        }
    }

    /// Apple's charging composite carries its own gap in the outline where the bolt crosses.
    /// The plug has no such composite, so a dilated copy is punched through fill and outline
    /// together — cutting the outline, not just the fill, is what the reference shows.
    ///
    /// The dilation is anchored on `bodyCentreFraction` because that is where `plugGlyph` puts
    /// its ink. `scaleEffect`'s default anchor is the *layout frame's* centre, which the glyph's
    /// own `.offset(x:)` has moved the ink away from, so the dilated copy lands off to one side:
    /// measured 0.0335 · `batteryWidth` more gap on the left than on the right, at every size.
    @ViewBuilder private var plugKnockout: some View {
        if showPowerIcon && !isCharging {
            plugGlyph
                .scaleEffect(Self.plugKnockoutScale,
                             anchor: UnitPoint(x: Self.bodyCentreFraction, y: 0.5))
                .blendMode(.destinationOut)
        }
    }

    var body: some View {
        ZStack {
            ZStack {
                fillBar
                outline
            }
            .compositingGroup()
            .overlay { plugKnockout }
            .compositingGroup()

            powerGlyph
        }
        .frame(width: batteryWidth, height: height)
    }
}

/// A view that displays the battery status.
struct BoringBatteryView: View {

    @State var batteryWidth: CGFloat = BatteryView.menuBarWidth
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false

    private static let labelPointSize: CGFloat = NSFont.preferredFont(forTextStyle: .callout).pointSize

    /// The menu bar pairs its 25.5 pt battery with 12 pt text, so the glyph tracks the
    /// label's point size. `batteryWidth` is the explicit ink width used when there is no
    /// label to scale against.
    private var iconWidth: CGFloat {
        guard Defaults[.showBatteryPercentage] else { return batteryWidth }
        return Self.labelPointSize * (BatteryView.menuBarWidth / 12)
    }

    var body: some View {
        // 4 pt of spacing plus the "%" side bearing lands on the menu bar's 5 pt visual gap.
        HStack(spacing: 4) {
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
                batteryWidth: iconWidth,
                isForNotification: isForNotification
            )
        }
    }
}

#Preview("Battery States") {
    VStack(alignment: .trailing, spacing: 12) {
        ForEach(
            [
                ("100%", Float(100), false, false, false),
                ("54%", Float(54), false, false, false),
                ("20%", Float(20), false, false, false),
                ("5%", Float(5), false, false, false),
                ("60% low power", Float(60), false, false, true),
                ("50% charging", Float(50), true, true, false),
                ("100% plugged in", Float(100), false, true, false),
            ],
            id: \.0
        ) { label, level, charging, plugged, lowPower in
            HStack(spacing: 12) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("\(Int32(level))%").font(.callout).foregroundStyle(.white)
                    BatteryView(
                        levelBattery: level,
                        isPluggedIn: plugged,
                        isCharging: charging,
                        isInLowPowerMode: lowPower,
                        isForNotification: true
                    )
                }
            }
        }
    }
    .padding(20)
    .background(Color.black)
}
