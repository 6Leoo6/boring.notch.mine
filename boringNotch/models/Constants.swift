//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

// How long a "keep awake" session lasts before sleep is allowed again
enum KeepAwakeDuration: Int, CaseIterable, Identifiable, Defaults.Serializable {
    case indefinite = 0
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400

    var id: Int { self.rawValue }

    var seconds: TimeInterval? {
        self == .indefinite ? nil : TimeInterval(self.rawValue)
    }

    var label: String {
        switch self {
        case .indefinite: return "Until turned off"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        }
    }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: false)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: false)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: true)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.albumArt
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: true)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)

    // MARK: Keep awake
    static let showKeepAwake = Key<Bool>("showKeepAwake", default: true)
    static let keepAwakeDuration = Key<KeepAwakeDuration>("keepAwakeDuration", default: .indefinite)
    static let keepAwakePreventsDisplaySleep = Key<Bool>("keepAwakePreventsDisplaySleep", default: false)
    static let keepAwakeRestoreOnLaunch = Key<Bool>("keepAwakeRestoreOnLaunch", default: false)
    static let keepAwakeWasActive = Key<Bool>("keepAwakeWasActive", default: false)

    // MARK: Flashlight
    static let flashlightRaisesBrightness = Key<Bool>("flashlightRaisesBrightness", default: true)
    // Fraction of the screen the light covers, 0...1. Doubles as the brightness control.
    static let flashlightPanelSize = Key<Double>("flashlightPanelSize", default: 0.6)
    // Crash recovery, not a user setting: display brightness is a system setting that
    // outlives this process, so the pre-flashlight value is parked here while the
    // flashlight drives brightness. A value surviving into the next launch means a crash
    // stranded the display and it must be restored. -1 means nothing to restore.
    static let flashlightRestoreBrightness = Key<Double>("flashlightRestoreBrightness", default: -1)

    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: false)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    
    // MARK: Clipboard
    static let clipboardHistoryEnabled = Key<Bool>("clipboardHistoryEnabled", default: true)
    static let clipboardHistoryDays = Key<Int>("clipboardHistoryDays", default: 30)
    static let clipboardMaxEntries = Key<Int>("clipboardMaxEntries", default: 200)
    static let clipboardDeleteConfirmEnabled = Key<Bool>("clipboardDeleteConfirmEnabled", default: false)
    /// Hide entries that look like secrets, or came from a password manager, from agents.
    static let clipboardAutoProtectSecrets = Key<Bool>("clipboardAutoProtectSecrets", default: true)

    // MARK: Agent bridge (local MCP)
    /// Off by default: turning it on exposes the shelf and clipboard history to local agents.
    static let agentBridgeEnabled = Key<Bool>("agentBridgeEnabled", default: false)
    static let shelfDeleteConfirmEnabled = Key<Bool>("shelfDeleteConfirmEnabled", default: true)
    static let shelfGridExpanded = Key<Bool>("shelfGridExpanded", default: true)

    // MARK: Mirror shot
    /// Whether the mirror offers a shutter at all.
    static let mirrorShotEnabled = Key<Bool>("mirrorShotEnabled", default: true)
    /// Whether Space takes the shot while the pointer is over the mirror.
    static let mirrorShotSpaceShortcut = Key<Bool>("mirrorShotSpaceShortcut", default: true)

    // MARK: Screen capture
    static let screenCaptureEnabled = Key<Bool>("screenCaptureEnabled", default: true)
    /// Whether the notch header shows the capture buttons. Separate from
    /// `screenCaptureEnabled`: this is chrome visibility, that is the feature switch.
    static let showCaptureControls = Key<Bool>("showCaptureControls", default: true)
    /// Screenshots land on the clipboard instead of on disk. Default because it is the one
    /// path that needs no filesystem access at all under the sandbox, and because this app's
    /// own clipboard history then picks the shot up.
    static let screenCaptureToClipboard = Key<Bool>("screenCaptureToClipboard", default: true)
    static let screenCaptureSaveLocation = Key<String>("screenCaptureSaveLocation", default: defaultScreenCaptureLocation)
    /// Companion to `screenCaptureSaveLocation`, not a user setting: the sandbox grants access
    /// to a folder the user picked in an open panel, and only a security-scoped bookmark
    /// carries that grant across launches. The path string alone opens nothing.
    static let screenCaptureSaveBookmark = Key<Data?>("screenCaptureSaveBookmark", default: nil)
    static let screenCaptureIncludeCursor = Key<Bool>("screenCaptureIncludeCursor", default: false)
    static let screenCapturePlaySound = Key<Bool>("screenCapturePlaySound", default: true)

    // MARK: Tab routing
    static let autoTabRouting = Key<Bool>("autoTabRouting", default: true)
    /// Tab a modifier held while the pointer opens the notch jumps to. Outranks every
    /// routing signal, including `autoTabRouting` being off.
    static let commandHoverRoute = Key<ModifierRoute>("commandHoverRoute", default: ModifierRoute.clipboard)
    static let optionHoverRoute = Key<ModifierRoute>("optionHoverRoute", default: ModifierRoute.shelf)
    static let lastShelfPanel = Key<ShelfPanel>("lastShelfPanel", default: ShelfPanel.clipboard)
    static let shelfDropBoostMinutes = Key<Int>("shelfDropBoostMinutes", default: 3)
    static let clipboardCopyBoostSeconds = Key<Int>("clipboardCopyBoostSeconds", default: 60)
    static let shelfLastDropAt = Key<Date>("shelfLastDropAt", default: .distantPast)
    static let clipboardLastCopyAt = Key<Date>("clipboardLastCopyAt", default: .distantPast)
    static let shelfUseScore = Key<Double>("shelfUseScore", default: 0)
    static let shelfUseScoreAt = Key<Date>("shelfUseScoreAt", default: .distantPast)

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: MediaControllerType.spotify)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    /// macOS puts screenshots on the Desktop, so that is what this matches.
    ///
    /// Resolved through `getpwuid` rather than `NSHomeDirectory()` or a `FileManager` search
    /// path: this app is sandboxed, and both of those answer with the container, whose
    /// `Desktop` and `Pictures` entries are symlinks back to the real folders that the sandbox
    /// then refuses to write through. The real path is the honest default to show the user;
    /// `ScreenCaptureManager` is what deals with actually being allowed to write there.
    static var defaultScreenCaptureLocation: String {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return String(cString: home) + "/Desktop"
        }
        return NSHomeDirectory() + "/Desktop"
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
