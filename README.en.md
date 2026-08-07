# DiskTidy

A macOS disk-cleanup utility. Review and clear app caches, simulators, build caches, and large files from one window.

[한국어](README.md) · MIT License

> The app UI is currently Korean-only. Localization contributions are welcome.

<img src="docs/screenshots/01-storage.png" width="820" alt="DiskTidy SSD usage screen">

## Screens

| | |
|---|---|
| **App caches** — `~/Library/Caches` by size<br><img src="docs/screenshots/02-cache.png" width="400" alt="App caches screen"> | **Simulators** — least recently used on top<br><img src="docs/screenshots/03-simulator.png" width="400" alt="Simulators screen"> |
| **Project caches** — recursive build-cache scan<br><img src="docs/screenshots/04-project-cache.png" width="400" alt="Project caches screen"> | **Large files** — files over 200 MB<br><img src="docs/screenshots/06-big-files.png" width="400" alt="Large files screen"> |
| **Android caches** — Gradle · Android Studio<br><img src="docs/screenshots/07-android-cache.png" width="400" alt="Android caches screen"> | **Android emulators** — AVD list<br><img src="docs/screenshots/08-android-emulator.png" width="400" alt="Android emulators screen"> |

The menu-bar item shows SSD usage at all times; clicking it opens a minimal dropdown.

<img src="docs/screenshots/09-menubar.png" width="240" alt="Menu bar dropdown">

> These are real screenshots from daily use. Only the personal parts — cache entry names and project paths — are blurred.

## Features

Eight screens in a sidebar, plus a persistent menu-bar item.

| Screen | Contents |
|---|---|
| SSD usage | Total / used / free capacity and usage percentage |
| App caches | Per-app directories under `~/Library/Caches` |
| Simulators | iOS simulators sorted by last use; delete device or erase data |
| Project caches | Recursive scan for build caches under folders you pick (rules below) |
| Xcode caches | `DerivedData`, iOS/watchOS/tvOS DeviceSupport, Archives |
| Large files | Files over 200 MB under folders you pick (defaults to `~/Downloads`) |
| Android caches | Gradle caches and distributions, `~/.android` caches, Android Studio IDE caches |
| Android emulators | AVDs in `~/.android/avd`; deletion also clears the `.ini` pointer |

The menu-bar item shows SSD usage, refreshed every 60 seconds. Clicking it opens a minimal dropdown with a gauge plus Open / Quit.

## Project cache detection rules

Directories whose names unambiguously mean "build cache" are matched by name. Generic names require a marker file in the parent directory.

| Rule | Directories | Condition |
|---|---|---|
| By name | `Pods` `DerivedData` `.gradle` `Carthage` `.dart_tool` `.next` `.expo` | none |
| Marker required | `node_modules` `dist` | `package.json` in parent |
| Marker required | `target` | one of `Cargo.toml` `pom.xml` `build.gradle` `build.gradle.kts` |
| Marker required | `build` | one of `package.json` `build.gradle` `build.gradle.kts` `CMakeLists.txt` `pom.xml` |
| Marker required | `.build` | `Package.swift` in parent |

`build`, `dist`, and `target` can be committed source directories, so they are left alone without a marker. Overly broad scan roots (`/`, `~`, `/Users`, …) are rejected.

## Deletion policy

- App caches, project caches, Xcode caches, large files, Android caches, Android emulators: **moved to Trash** (`FileManager.trashItem`) — recoverable.
- Simulator delete / erase: `xcrun simctl delete` / `erase` — irreversible, so a confirmation dialog is shown first.
- Failures (insufficient permissions, files in use, booted simulators) surface as an in-app warning banner and the item stays in the list. Details go to Console.app under the `com.jimmy.disktidy` subsystem.

## Requirements

- macOS 13 or later
- Xcode 16 or later (Swift Testing)
- macOS will prompt for file access (TCC) to `~/Documents`, `~/Downloads`, etc. on first run

## Running

```bash
./Scripts/run.sh          # dev mode (release build, runs immediately, shows a Dock icon)
swift test                # tests
```

## Installation

### Download (DMG)

**Step 1.** Grab `DiskTidy-<version>.dmg` from [Releases](../../releases), open it, and drag `DiskTidy.app` onto `Applications`.

<img src="docs/screenshots/10-install-dmg.png" width="600" alt="Open the DMG and drag DiskTidy.app onto Applications">

Verify integrity:

```bash
shasum -a 256 -c DiskTidy-1.0.dmg.sha256
```

### Build from source

```bash
./Scripts/build-app.sh    # release build → DiskTidy.app → installs to ~/Applications
./Scripts/make-dmg.sh     # release build → dist/DiskTidy-<version>.dmg + .sha256
./Scripts/make-app.sh     # DiskTidy.app bundle only (no install, no packaging)
```

`LSUIElement=true` in `Info.plist` means the installed `.app` lives only in the menu bar, with no Dock icon.

### First launch (Gatekeeper)

This app is **ad-hoc signed (free) and therefore not notarized by Apple.** macOS will block the first launch with the warning below. That is expected.

<img src="docs/screenshots/11-install-gatekeeper.png" width="260" alt="Gatekeeper warning: 'DiskTidy' Not Opened">

> **Do not click Move to Trash.** Click `Done` and follow the steps below.

**macOS 15 Sequoia and later** — Apple removed the right-click → Open bypass. Allow it this way:

1. Launch `DiskTidy.app` once, then dismiss the block warning
2. Go to **System Settings → Privacy & Security**
3. Scroll down to the DiskTidy entry and click **"Open Anyway"**

**macOS 13–14** — **right-click → Open** once; subsequent launches work normally.

**From the terminal** (works on any version):

```bash
xattr -dr com.apple.quarantine /Applications/DiskTidy.app
```

To inspect the signature before trusting it:

```bash
codesign -dv --verbose=4 /Applications/DiskTidy.app
```

Each build generates a fresh ad-hoc signature, so macOS may re-ask for folder permissions (TCC) after reinstalling.

**If you fork:** change `CFBundleIdentifier` in `Info.plist` (`com.jimmy.disktidy`) and the logger subsystem in `TrashService` to your own. To notarize, you need an Apple Developer Program membership ($99/year), then `codesign --options runtime --sign "Developer ID Application: ..."` plus `xcrun notarytool submit`.

## Design notes

- **`ShellRunner` discards stderr via `FileHandle.nullDevice`.** With a `Pipe`, once the child fills the 64 KB pipe buffer it blocks on write while the parent waits forever reading stdout. `find`'s "Permission denied" output alone exceeds that, and the app really did hang. Covered by a regression test.
- **`DiskScanner.sizes(of:)` batches paths into one `du -sk` call.** Spawning one process per entry means 100+ fork/exec calls for `~/Library/Caches` alone.
- **Six cache tabs share a single `CleanableListViewModel`,** injecting only the scanner closure. Scanning and deletion both run off the main thread, and refresh is guarded against re-entry.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---
Author: JunyoungJung
