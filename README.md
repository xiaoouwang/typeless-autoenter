# Typeless AutoEnter

[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos/)
[![Objective-C](https://img.shields.io/badge/language-Objective--C-blue)](https://developer.apple.com/documentation/objectivec)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[中文](README_CN.md) | **English**

Automatically presses Enter and/or Tab after [Typeless](https://typeless.com) finishes voice-to-text input on macOS.

## Why

Typeless pastes recognized text via `Cmd+V`, but many workflows still need a follow-up key press. This tool detects that paste event and simulates Enter and/or Tab after a 500ms delay, so your hands can stay off the keyboard entirely.

## How it works

1. Scans running processes every 30s to find Typeless by name
2. Listens for global `keyDown` events via `CGEvent Tap`
3. Filters by PID — only reacts to `Cmd+V` from the Typeless process
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

On first launch, macOS requires **Accessibility** permission. If permission is missing, the app opens the Accessibility settings page automatically and shows an alert with the binary path.

**Steps to authorize:**

1. Open **System Settings** (or System Preferences on older macOS)
2. Go to **Privacy & Security → Accessibility**
3. Click the **+** button (you may need to unlock with your password first)
4. Navigate to `TypelessAutoEnter.app` and add it
5. Make sure the toggle next to it is **enabled**
6. Relaunch the app

You only need to do this once. The `.app` bundle has a stable `CFBundleIdentifier`, so macOS remembers the permission even after recompiling.

### Menu bar

A menu bar icon appears (`↩`, `⇥`, or `↩⇥`). Click it to toggle `AutoEnter` / `AutoTab`.

- Enabled: icon at full opacity
- Disabled: icon grayed out

### Global shortcut

`Ctrl + Shift + Enter` toggles `AutoEnter`.

`Ctrl + Shift + Tab` toggles `AutoTab`.

A frosted-glass HUD flashes on screen to confirm each toggle.

To change the shortcut, edit line 127-131 in `typeless-autoenter.m` and recompile. The modifier keys are:

| Flag | Key |
|------|-----|
| `kCGEventFlagMaskControl` | Ctrl |
| `kCGEventFlagMaskShift` | Shift |
| `kCGEventFlagMaskCommand` | Cmd |
| `kCGEventFlagMaskAlternate` | Option |

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
