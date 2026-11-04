<p align="center">
  <img src="Resources/icon/AppIcon-1024.png" width="128" alt="MiniTab icon">
</p>

<h1 align="center">MiniTab</h1>

<p align="center">
  A lightweight, privacy-conscious window switcher for macOS.<br>
  Every window, most recently used first, across apps, Spaces, full-screen apps and displays.
</p>

---

MiniTab replaces app-level switching with **window-level** switching: hold <kbd>⌥</kbd> (or <kbd>⌘</kbd>), press <kbd>Tab</kbd>, and pick any open window from a grid of live thumbnails. It is a single native Swift app with no third-party dependencies, no network access and no telemetry, small enough to audit in an afternoon.

## Features

- **Window-level switching** with thumbnails, ordered by recent use across all apps.
- **All Spaces and full-screen apps**, including minimized and hidden windows; picking one takes you there.
- **Multi-display aware**: the switcher opens on the display you're working on.
- **Keyboard and mouse**: the selection follows the pointer; click to switch.
- **Search** windows by title or app name.
- **Window actions** from the switcher: close, minimize, quit (quit requires a hold, so it can't happen by accident).
- **Optional ⌘Tab replacement** that hands the shortcut back to macOS when MiniTab quits.
- **Icons-only mode** that needs no Screen Recording permission.
- **Launch at login**, menu bar only (no Dock icon).

## Requirements

- macOS 14 Sonoma or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Installation

MiniTab is distributed as source. Build and install it with the included script:

```bash
git clone https://github.com/lftorresg/minitab.git
cd minitab
./build.sh --install
```

This builds a release binary, signs it with the hardened runtime, copies `MiniTab.app` to `/Applications` and launches it. Running `./build.sh` without `--install` only builds into `build/`.

On first launch, grant the permissions below in **System Settings → Privacy & Security**, then enable **Launch at Login** from the menu bar icon.

### Permissions

| Permission | Used for | Required |
|---|---|---|
| Accessibility | The keyboard shortcut, reading window titles and state, focusing and acting on windows | Yes |
| Screen Recording | Window thumbnails | Only when **Show Thumbnails** is on |

You can review the current state at any time from **menu bar icon → Check Permissions…**.

## Usage

| Keys (while holding ⌥ or ⌘) | Action |
|---|---|
| <kbd>Tab</kbd> / <kbd>Shift</kbd><kbd>Tab</kbd> | Next / previous window |
| Arrow keys | Move the selection |
| Release the modifier, <kbd>Return</kbd> or <kbd>Space</kbd> | Switch to the selected window |
| <kbd>Esc</kbd> | Cancel |
| <kbd>S</kbd> | Search by window title or app name |
| <kbd>W</kbd> | Close the selected window |
| <kbd>M</kbd> | Minimize the selected window |
| Hold <kbd>Q</kbd> (~0.7 s) | Quit the selected window's app |

- A quick tap switches straight to the previous window without showing the panel.
- Moving the pointer over a window selects it; clicking switches to it. The ✕ button on the selected window closes it.
- In search mode the panel stays open after you release the modifier. <kbd>Return</kbd> switches, <kbd>Esc</kbd> cancels.
- <kbd>S</kbd>, <kbd>W</kbd>, <kbd>M</kbd> and <kbd>Q</kbd> are physical key positions, so they work the same on any QWERTY-based layout.

### Menu bar options

| Option | Description |
|---|---|
| Check Permissions… | Permission status and keyboard mode |
| Launch at Login | Start MiniTab automatically |
| Replace ⌘Tab | Use ⌘ instead of ⌥. The system ⌘Tab is disabled while MiniTab runs and restored when it quits |
| Show Thumbnails | Off: icons-only mode, no screen capture, no Screen Recording permission |
| Include Other Spaces | Off: current Space only, and no private APIs related to Spaces are used |
| Show Switcher On | Display with the active window (default), display with the pointer, or the primary display |
| Copy Window Diagnostics | Copies what MiniTab sees about every window to the clipboard, for troubleshooting |

## Privacy and security

MiniTab needs powerful permissions, so it is designed to use as little of them as possible and to make that easy to verify.

- **No network, no telemetry, no files.** The only thing written to disk is its own preferences.
- **No keystroke visibility while idle.** The opening shortcut is a registered system hotkey, so macOS only reports that exact key combination. A keyboard event tap is enabled only while the switcher is open and disabled as soon as it closes. Search text lives in memory until the switcher closes.
- **Short-lived thumbnails.** Window images are kept in memory only, reused for a few seconds while switching and discarded 30 seconds after the switcher closes. The panel is excluded from screen sharing and recordings made by other apps.
- **Untrusted input is validated.** Values returned through the Accessibility API come from other apps, so their types are checked before use, and every Accessibility call has a 0.25 s timeout.
- **Conservative actions.** Close and minimize act only on an exact window ID; quit verifies it is still the same app instance before acting.
- **Recency tracking stores IDs only.** Window IDs (up to 128), never titles or content.
- **Hardened runtime.** The build is signed with `--options runtime` and the signature is verified.

### Code signing

MiniTab supports two signing modes.

**Ad-hoc (default).** macOS ties MiniTab's permissions to the exact binary, so nothing else can ever inherit them. The trade-off is that each new build needs the permissions enabled again. `./build.sh --install` clears the outdated entries automatically: Accessibility reappears and only needs switching on, while Screen Recording must be re-added with **+** (the script opens the pane and reveals the app).

**Local signing identity (optional).** Permissions survive rebuilds. Run once:

```bash
./scripts/setup-signing.sh
```

This creates a self-signed code-signing certificate in a dedicated, password-protected keychain that locks after five minutes and on sleep, and that grants no application silent access to the key. The certificate is marked as trusted for code signing only, in your user's trust settings (required for macOS to keep permissions across builds; it does not affect Gatekeeper). `build.sh` picks it up automatically. When signing, macOS asks for that keychain's password and whether `codesign` may use the key: choose **Allow**, never **Always Allow**.

Why the extra care: with a stable identity, macOS grants MiniTab's permissions to *any* binary signed with that key under MiniTab's bundle ID. Keeping the key locked and confirmation-gated ensures it can't be used silently. To remove it: `security delete-keychain ~/Library/Keychains/minitab-signing.keychain-db && rm .signing.env`.

## How it works

| File | Responsibility |
|---|---|
| `HotkeyTap.swift` | Registered hotkey; event tap active only while the switcher is open |
| `WindowProvider.swift` | Window list across Spaces, filtering of helper windows, Accessibility refinement |
| `WindowMRU.swift` | Most-recently-used order from app activations and per-app focus observers |
| `SwitcherPanel.swift` | The switcher UI in AppKit and Core Animation (no SwiftUI) |
| `Thumbnailer.swift` | Window thumbnails via ScreenCaptureKit |
| `WindowActions.swift` | Focus, close, minimize and quit |
| `WindowMenu.swift` | Fallback that focuses a window through its app's Window menu |
| `Spaces.swift`, `AXPrivate.swift`, `NativeSwitcher.swift` | Optional private APIs (see below) |
| `AppDelegate.swift` | App lifecycle, menu bar, settings, watchdogs |
| `build.sh`, `scripts/setup-signing.sh` | Build, sign and install; optional local signing identity |

### Private APIs

Some capabilities have no public API. MiniTab uses the following undocumented functions, loaded at runtime where possible so that their absence degrades functionality instead of preventing launch:

| Function | Purpose |
|---|---|
| `_AXUIElementGetWindow` | Map an Accessibility element to its window ID |
| `_AXUIElementCreateWithRemoteToken` | Reach windows on other Spaces, which the public Accessibility API does not list |
| `SLSMainConnectionID`, `SLSCopySpacesForWindows` | Determine which windows belong to a Space |
| `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo` | Bring a window on another Space to the front |
| `CGSSetSymbolicHotKeyEnabled` | Disable the system ⌘Tab (only with **Replace ⌘Tab**) |
| `GetProcessForPID` (deprecated, public) | Process serial number for the call above |

Turning off **Include Other Spaces** disables everything Spaces-related. Runtime loading cannot detect a *changed* function signature, so after a major macOS update, turn that option off if MiniTab misbehaves.

## Performance

- **Idle:** no polling; the event tap is off. MiniTab only reacts to focus changes to keep the recency order.
- **Quick switch:** a window list query and one focus call. Nothing is drawn or captured.
- **Opening the switcher:** the panel appears about 80 ms after the key press. Accessibility details are fetched afterwards on a background thread and merged in without moving the selection.
- **Moving the selection:** a single Core Animation layer moves.
- For the lowest footprint, turn off **Show Thumbnails** and/or **Include Other Spaces**.

## Troubleshooting

| Problem | Solution |
|---|---|
| Shortcut does nothing after a rebuild | Switch MiniTab on in Accessibility (and Screen Recording), or set up a local signing identity; see [Code signing](#code-signing) |
| MiniTab is missing from the Screen Recording list | macOS doesn't re-list ad-hoc signed apps there after a rebuild. Add it with **+** (`build.sh --install` opens the pane and reveals the app for you), enable it, then quit and reopen MiniTab. With a [local signing identity](#code-signing) this is needed only once |
| Permissions are stuck | `tccutil reset Accessibility io.github.lftorresg.minitab` (and `ScreenCapture`), then grant again |
| ⌘Tab stopped working after a crash | Launch MiniTab again (it restores the system ⌘Tab at startup), or log out and back in |
| Shortcut ignored in password fields | macOS Secure Input blocks keyboard monitoring; MiniTab falls back to switching to the previous window and shows ⚠︎ in the menu |
| A window is missing or shouldn't be listed | Use **Copy Window Diagnostics** and include the output in an issue (it contains window titles; review it first) |

## Known limitations

- The shortcut can only be ⌥Tab or ⌘Tab.
- DRM-protected video appears black in thumbnails. This is enforced by macOS.
- The screen-sharing exclusion depends on the capture method used by other apps; verify it with the tools you use.
