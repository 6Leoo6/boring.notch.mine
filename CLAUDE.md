# boring.notch — CLAUDE.md

Personal fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) for local customization on macOS.

---

## Live Development Workflow

### Running the App
- Open `boringNotch.xcodeproj` in Xcode and press `Cmd+R`, or use `BuildProject` via the xcode-tools MCP.
- The app has **no Dock icon** — it lives in the **menu bar** (sparkle icon) and renders a borderless overlay window positioned at the notch.
- To restart after a code change, use the menu bar → "Restart Boring Notch", or quit and re-run from Xcode.
- Kill any existing running instance before launching a new debug build: `pkill -x boringNotch` or quit via the menu bar first.

### Checking Code Without Full Build
- Use `XcodeRefreshCodeIssuesInFile` for instant compiler diagnostics on a single Swift file.
- Use `RunCodeSnippet` to try small experiments in the context of a file.
- Use `BuildProject` for full build validation before considering a change done.

### Previews
- SwiftUI Previews work for individual views but **not** for notch-positioned windows (they require the full app window stack).
- Self-contained subviews (settings panels, calendar, shelf items) are good candidates for previews.

### Settings
- Open Settings with `Cmd+,` from the menu bar extra, or call `SettingsWindowController.shared.showWindow()`.
- All user preferences use the `Defaults` package — keys are defined in `models/Constants.swift`. Resetting a key: `Defaults.reset(.<key>)` in a `RunCodeSnippet`.

---

## Architecture

### Window Model
- `AppDelegate` owns `NSWindow` instances (`BoringNotchSkyLightWindow`, a subclass) positioned at the top-center of each screen.
- Single-display mode: one `window` + one `vm: BoringViewModel`.
- Multi-display mode: `windows: [UUID: NSWindow]` + `viewModels: [UUID: BoringViewModel]`.
- Windows are borderless, non-activating panels — they never steal focus.

### State
| Type | Purpose |
|---|---|
| `BoringViewModel` | Per-window notch state (open/closed, drag targeting, camera) |
| `BoringViewCoordinator.shared` | Cross-window coordination (active tab, sneak peek, first-launch) |
| `Defaults[.<key>]` | Persisted user settings (from `Constants.swift`) |
| `MusicManager.shared` | Now-playing state and playback control |
| `*Manager.shared` | All other feature managers are singletons |

### Key Files
| File | Role |
|---|---|
| `boringNotchApp.swift` | `@main`, `AppDelegate`, window lifecycle |
| `BoringViewCoordinator.swift` | Shared coordinator singleton |
| `models/BoringViewModel.swift` | Per-screen notch view model |
| `models/Constants.swift` | All `Defaults.Keys` |
| `components/Notch/NotchHomeView.swift` | Root view rendered inside the notch |
| `sizing/matters.swift` | Notch sizing helpers (`getClosedNotchSize`, `windowSize`) |

### Adding a New Feature
1. Create a manager/service in `managers/` if stateful.
2. Add any persistent settings as `Defaults.Key` in `Constants.swift`.
3. Add UI in `components/` following existing SwiftUI patterns.
4. Wire into `NotchHomeView` or the relevant tab.
5. Avoid Combine; use `async/await` and `@Published` + `Task {}` instead.

### Tabs / Navigation
- `BoringViewCoordinator.currentView` controls which tab is shown when the notch is open.
- Tab values are in `enums/generic.swift` (`TabSelectionValue` or similar).

---

## Coding Conventions

- **No force unwrapping** — use `guard let` or optional chaining.
- **No Combine** — use `async/await`, `Task`, and `@Published`.
- **Singletons** via `static let shared = ...`.
- **Settings** always via `Defaults[.<key>]`, never `UserDefaults` directly.
- **Animations** use the `Pow` package or SwiftUI's `.animation()` — match the existing spring/ease style.
- **No comments** on obvious code; add one only when the why is non-obvious.
- 4-space indentation, PascalCase types, camelCase properties.

---

## Project Layout

```
boringNotch/
├── boringNotchApp.swift          # Entry point + AppDelegate
├── ContentView.swift             # Root SwiftUI view per window
├── BoringViewCoordinator.swift   # Shared coordinator
├── models/                       # ViewModels + Constants
├── managers/                     # Feature managers (Music, Battery, Volume…)
├── MediaControllers/             # Apple Music, Spotify, YouTube Music, NowPlaying
├── components/
│   ├── Notch/                    # Window + home view
│   ├── Music/                    # Visualizer, Lottie animation
│   ├── Shelf/                    # File shelf (drop zone, AirDrop)
│   ├── Calendar/                 # Calendar widget
│   ├── Settings/                 # Settings window
│   ├── Live activities/          # Battery HUD, volume HUD, download indicator
│   ├── Tabs/                     # Tab bar UI
│   └── Onboarding/
├── observers/                    # DragDetector, FullscreenMediaDetection
├── helpers/                      # Utilities (AppleScript, AudioPlayer…)
├── extensions/                   # Swift/AppKit/SwiftUI extensions
├── sizing/matters.swift          # Notch size calculations
└── enums/generic.swift           # Shared enums
BoringNotchXPCHelper/             # Privileged XPC helper target
mediaremote-adapter/              # Perl script for media remote bridging
```

---

## Personal Customization Notes

> Add notes here as you modify the app for personal use.

### Agent bridge (local MCP)
- The app serves `POST /rpc` on `127.0.0.1:<random port>` (`managers/AgentBridgeServer.swift`, ops in `AgentBridgeRouter.swift`) when `Defaults[.agentBridgeEnabled]` is on. Port + per-launch token go to `~/.config/boringnotch/agent-bridge.json` (0600), allowed by a home-relative sandbox exception in the entitlements.
- MCP itself lives in `mcp-helper/` (SwiftPM, no dependencies). It runs unsandboxed as the agent's child and does all file I/O, because the sandboxed app cannot read or write agent-named paths. Rebuild and reinstall with `mcp-helper/install.sh`.
- Protection: `ClipboardEntry.protectionOverride` (nil = auto) + `ClipboardProtection` (password-manager bundle IDs, secret regexes), with auto-detection controlled by `Defaults[.clipboardAutoProtectSecrets]`. Protected entries are listed without content.
- To enable a Bool key for one launch without writing the sandboxed prefs: `open -a boringNotch.app --args -<key> '<true/>'` (a bare `YES` arrives as a String and Defaults ignores it).

<!-- Example:
- Disabled the volume HUD (changed `showVolumeHUD` default to false in Constants.swift)
- Increased default notch open animation speed
-->
