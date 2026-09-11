//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

public enum Style {
    case notch
    case floating
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    case shelf
}

public enum ShelfPanel: String, Defaults.Serializable {
    case shelf
    case clipboard
}

/// Where a modifier held while the pointer opens the notch sends it.
///
/// `off` rather than `none` deliberately: an enum case named `none` collides with
/// `Optional.none` at every comparison site and makes the routing read ambiguously.
public enum ModifierRoute: String, CaseIterable, Defaults.Serializable {
    case off
    case home
    case shelf
    case clipboard

    var label: String {
        switch self {
        case .off: return "Nothing"
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard history"
        }
    }
}

/// What started an open. Only a POINTER-initiated open reads the modifier keys: the notch has
/// a keyboard shortcut of its own (⌘⇧I by default) and so does the clipboard panel (⇧⌘C), so
/// reading the flags on a shortcut open would route every one of them to whatever Command is
/// bound to. A drag counts as `system` for the same kind of reason — ⌥ is the Finder's copy
/// modifier and is routinely held over a drop.
public enum NotchOpenTrigger {
    case pointer
    case system
}

enum SettingsEnum {
    case general
    case about
    case charge
    case download
    case mediaPlayback
    case hud
    case shelf
    case extensions
}

enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
}

enum DownloadIconStyle: String, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}

enum MirrorShapeEnum: String, Defaults.Serializable {
    case rectangle = "Rectangular"
    case circle = "Circular"
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
}
