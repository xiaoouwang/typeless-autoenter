# Typeless AutoEnter

[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos/)
[![Objective-C](https://img.shields.io/badge/language-Objective--C-blue)](https://developer.apple.com/documentation/objectivec)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[中文](README_CN.md) | **English**

Automatically presses Enter and/or Tab after [Typeless](https://typeless.com) or [Wispr Flow](https://wisprflow.ai) finishes voice-to-text input on macOS. Choose which app to monitor from the menu bar.

## Why

Voice tools like Typeless and Wispr Flow paste recognized text via `Cmd+V`, but many workflows still need a follow-up key press. This tool detects that paste event and simulates Enter and/or Tab after a 500ms delay, so your hands can stay off the keyboard entirely.

## Codex workflow

This release adds a Codex-oriented Tab flow:

1. In the menu bar, select the voice app you use (`Typeless` or `Wispr Flow`)
2. Turn on `AutoTab` with `Ctrl + Shift + Tab`
3. Speak with the selected app
4. After it pastes text, this app sends `Tab` automatically

In Codex UIs/workflows where `Tab` means "queue next command", your new command is pushed behind the currently running task.  
Note: the queue behavior itself is provided by the target app (Codex), while this tool is responsible for sending the key event at the right time.

## What's new (2026-07)

### Features

- Monitor either **Typeless** or **Wispr Flow** — pick one from the menu bar (`Monitor App`); selection is persisted across launches

## What's new (2026-03)

### Features

- `AutoEnter` and `AutoTab` are independent toggles and can be enabled together
- New global shortcut: `Ctrl + Shift + \`` to show a status snapshot without changing toggle state
- UI language switching is built in (default Chinese, in-app toggle to English)
- Startup language override is supported via `--lang`, `--ui-lang`, and `TYPELESS_UI_LANG`
- Permission UX upgrade: automatically opens the Accessibility page when permission is missing

### Bug fixes

- Fixed accidental `Cmd+Tab` behavior by clearing modifier flags before posting synthetic key events
- Fixed status snapshot highlight logic: Enter and Tab are now independently bright/dim
- Fixed HUD icon alignment: single-icon and dual-status rendering are centered correctly
- Status bar Tab icon now uses a single symbol (`⇥`) for stable cross-device rendering
- Refined status bar spacing and baseline alignment for Enter/Tab icon pairing

## How it works

1. Scans running processes every 30s to find the selected monitor target (`Typeless` or `Wispr Flow`) by process name
2. Listens for global `keyDown` events via `CGEvent Tap`
3. Filters by PID — only reacts to `Cmd+V` from that app's process
4. Waits 500ms (resets if another `Cmd+V` arrives), then simulates enabled key actions (Enter and/or Tab)

## Build

```bash
chmod +x build.sh
./build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).

The build script compiles the source, packages it into a `TypelessAutoEnter.app` bundle, and code-signs it. The `.app` bundle ensures macOS reliably remembers the Accessibility permission across restarts.

## Usage

```bash
open TypelessAutoEnter.app
# or run the binary directly:
TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter
```

### UI copy (Chinese / English)

Default UI copy is **Chinese**.

Switch to English UI:

1. Open the menu bar app menu
2. Click `界面语言：中文` once
3. It will become `UI Language: English` and all UI text switches to English

Switch back to Chinese UI:

- Click `UI Language: English`

Start directly in English UI (without manual click):

```bash
# option 1: command argument
TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter --lang en

# option 2: environment variable
TYPELESS_UI_LANG=en open TypelessAutoEnter.app
```

Supported values: `en`, `english`, `zh`, `cn`, `zh-cn`, `chinese`.

On first launch, macOS requires **Accessibility** permission. If permission is missing, the app opens the Accessibility settings page automatically and shows an alert with the binary path.

**Steps to authorize:**

1. Open **System Settings** (or System Preferences on older macOS)
2. Go to **Privacy & Security → Accessibility**
3. Click the **+** button (you may need to unlock with your password first)
4. Navigate to `TypelessAutoEnter.app` and add it
5. Make sure the toggle next to it is **enabled**
6. Relaunch the app

You only need to do this once. The `.app` bundle has a stable `CFBundleIdentifier`, so macOS remembers the permission even after recompiling.

### System UX updates

- Clearer runtime prompts for toggles and status snapshot
- Automatic jump to **Accessibility** settings when permission is missing
- Permission alert now explicitly reminds you to relaunch the app after granting access
- HUD layout tuned for two-key status text, with the same frosted-glass style
- Status snapshot now renders Enter/Tab independently: enabled key is bright, disabled key is dim
- Status bar icon rendering updated to symbol-based `⇥` + tuned spacing/baseline

### Menu bar

A menu bar icon appears (`↩`, `⇥`, or `↩  ⇥`). Click it to open the menu:

- Toggle `AutoEnter` / `AutoTab`
- Under **Monitor App**, choose **Typeless** or **Wispr Flow** (exclusive; only one is monitored at a time). The choice is saved and restored on next launch.

- Enabled: icon at full opacity
- Disabled: icon grayed out

### Global shortcut

`Ctrl + Shift + Enter` toggles `AutoEnter`.

`Ctrl + Shift + Tab` toggles `AutoTab`.

`Ctrl + Shift + \`` shows the current state snapshot (`Enter` + `Tab`) without toggling.

A frosted-glass HUD flashes on screen for both toggle and state snapshot actions.

The `Ctrl + Shift + \`` shortcut is matched by physical keycode (`kVK_ANSI_Grave`), so it works regardless of current input method (English/Chinese/etc.).

### Shortcut management (disable / modify)

Edit `typeless-autoenter.m`, then rebuild with `./build.sh`.

Disable one shortcut:

- Find the matching branch in `event_callback` and comment it out.
- Examples: `keycode == kVK_Return` (AutoEnter), `keycode == kVK_Tab` (AutoTab), `keycode == kVK_ANSI_Grave` (status snapshot)

Change shortcut key:

- Keep the `Ctrl + Shift` modifier check.
- Replace the key constant in that branch with the one you want.

Disable all global shortcuts:

- Remove or comment the whole "shortcut handling" block in `event_callback`.
- The menu items still work.

Useful constants:

| Flag | Key |
|------|-----|
| `kCGEventFlagMaskControl` | Ctrl |
| `kCGEventFlagMaskShift` | Shift |
| `kCGEventFlagMaskCommand` | Cmd |
| `kCGEventFlagMaskAlternate` | Option |
| `kVK_Return` | Enter |
| `kVK_Tab` | Tab |
| `kVK_ANSI_Grave` | ` (backquote / tilde key) |

### Toggle via script

```bash
./toggle.sh
```

Sends `SIGUSR1` to toggle without touching the menu bar.

## Customization

The delay before auto-pressing keys defaults to **500ms**. To change it, edit `DELAY_SEC` in `typeless-autoenter.m`:

```c
static const CFTimeInterval DELAY_SEC = 0.5;  // change to your preferred delay in seconds
```

Then recompile with `./build.sh`.

## Auto-start (launchd)

1. Edit `com.user.typeless-autoenter.plist` — replace the path with the actual path to your `.app` bundle's binary:
   ```
   /path/to/TypelessAutoEnter.app/Contents/MacOS/typeless-autoenter
   ```
2. Copy to LaunchAgents and load:

```bash
cp com.user.typeless-autoenter.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.typeless-autoenter.plist
```

## License

This project is licensed under the [MIT License](LICENSE).
