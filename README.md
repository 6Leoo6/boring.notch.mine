<h1 align="center">
  <br>
  <a href="http://theboring.name"><img src="https://framerusercontent.com/images/RFK4vs0kn8pRMuOO58JeyoemXA.png?scale-down-to=256" alt="Boring Notch" width="150"></a>
  <br>
  Boring Notch (personal fork)
  <br>
</h1>

A personal fork of [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) that turns the MacBook notch into a music, shelf and clipboard hub. It keeps all upstream features and adds clipboard history, screen capture, a flashlight, keep-awake, smarter tab routing and a local MCP server for AI agents.

<p align="center">
  <img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="Demo GIF" />
</p>

## Features from upstream

- Now playing controls and a live activity for Apple Music, Spotify, YouTube Music and any Now Playing source.
- Audio visualizer, optionally tinted to the album art.
- Calendar and Reminders integration.
- Mirror that shows a webcam preview inside the notch.
- Battery and charging indicator.
- File shelf with AirDrop and share service support.
- Replacements for the system volume, brightness and keyboard backlight HUDs.
- Customizable gestures, notch sizing and multi-display support.

## Added in this fork

### Clipboard history
- Keeps a history of copied text, images and files as a second panel in the Shelf tab.
- Entries can be pinned, which exempts them from the age and count limits.
- A full-size preview panel expands below the notch, and text entries can be edited in it and saved back to the history.
- Retention days, maximum entries and delete confirmation are set in Settings > Clipboard.
- Copies that password managers mark as concealed are never recorded.
- `Shift-Cmd-C` opens the clipboard panel directly.

### Screen capture
- A camera button in the notch header takes a screenshot of a selected region.
- A record button records a selected region and turns into a red timer you stop from the same spot.
- Captures go to the clipboard by default, so they also appear in clipboard history. Saving to a folder is an option in Settings.
- Capture runs in process through ScreenCaptureKit, because the sandboxed app cannot run `/usr/sbin/screencapture`.

### Mirror shot and flashlight
- A shutter button on the mirror copies a still framed the same way the mirror shows it (square crop, mirrored, rounded corners).
- Space takes the shot while the pointer is over the mirror. It is not bound anywhere else.
- A flashlight toggle on the mirror lights a warm pane on screen. Its size sets the brightness, and it can raise display brightness while active.

### Keep awake
- A header button prevents system sleep, with a selectable duration.
- Optionally prevents display sleep too, and can restore its state on launch.

### Tab routing
- When the notch opens, it picks the tab and shelf panel from recent activity: a drag in progress, a recent drop, ongoing shelf use or a recent copy.
- Holding Command while hovering opens the clipboard, and holding Option opens the shelf. Both are remappable in Settings > Shelf.
- Routing only runs on a real closed to open transition, so clicking an already open notch never changes the tab.

### UI changes
- Redesigned shelf and clipboard panels with a shared tile strip and a switcher set into the panel border.
- Player tinting drives the slider, visualizer and active states from one setting.
- A compact "now playing" peek drops below the closed notch on track change.
- Compact fixed-width calendar, and calendar clicks open Calendar.app.
- Battery indicator matched to the macOS menu bar original, including the charging and plugged-in glyphs.
- Horizontal swipe cycles tabs.

### Agent bridge (MCP)
- Lets local AI agents (Claude Code or any MCP client) use the shelf and clipboard history.
- Off by default. Turn it on in Settings > Agents > Allow local agents.
- The app listens only on `127.0.0.1` with a token that changes every launch. Port and token are written to `~/.config/boringnotch/agent-bridge.json` (mode 0600).
- Clipboard entries from password managers or that look like API keys, tokens or private keys are listed without content. Right-click any entry to hide it from agents or allow it.

| Tool | What it does |
|---|---|
| `shelf_list` | Lists shelf items with id, kind (file, text, link), name, size and original path. |
| `shelf_pull` | Writes a file item to a path (folders arrive zipped), or returns text and links inline. |
| `shelf_put` | Adds a file or folder (up to 64 MB), text or a link to the shelf. |
| `clipboard_list` | Lists history filtered by type, time window, pinned or protected state, with paging. |
| `clipboard_get` | Returns one entry in full. Images come inline or are saved to a path. |
| `clipboard_add` | Adds text, an image file or file paths to the history, optionally pinned. |

The MCP server is a separate stdio helper in [`mcp-helper/`](mcp-helper/). It runs unsandboxed as the agent's child process and does all file I/O. Install it with:

```bash
mcp-helper/install.sh
```

This builds the helper, installs it to `~/.local/bin/boringnotch-mcp` and registers it with Claude Code at user scope.

## Building from source

This fork has no prebuilt releases. Upstream releases and the Homebrew cask install the original app without the features above.

**Requirements:**
- macOS 15.6 or later
- Xcode 26 or later

```bash
git clone https://github.com/6Leoo6/boring.notch.mine.git
cd boring.notch.mine
open boringNotch.xcodeproj
```

- Set your own development team and bundle identifier in the target's Signing settings.
- Build and run with `Cmd+R`.
- The app has no Dock icon. It lives in the menu bar, and Settings open from there.
- Quit any running instance before launching a new build (`pkill -x boringNotch`).

## Credits

All base functionality comes from [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch). Support the original project on [Ko-fi](https://www.ko-fi.com/alexander5015) or join its [Discord](https://discord.gg/GvYcYpAKTu).

- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)**: provides the Now Playing source on macOS 15.4 and later.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)**: the basis for the first version of the shelf.
- Icon by [@maxtron95](https://github.com/maxtron95), website by [@himanshhhhuv](https://github.com/himanshhhhuv).

For the full list of licenses and attributions, see [Third-Party Licenses](./THIRD_PARTY_LICENSES).
