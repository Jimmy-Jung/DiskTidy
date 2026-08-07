# DiskTidy

A macOS disk-cleanup utility. Review and clear app caches, simulators, build caches, and large files from one window.

[한국어](README.md) · MIT License

> The app UI is currently Korean-only. Localization contributions are welcome.

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

## Installing as an app

```bash
./Scripts/build-app.sh    # release build → DiskTidy.app → installs to ~/Applications
```

`LSUIElement=true` in `Info.plist` means the installed `.app` lives only in the menu bar, with no Dock icon.

**First launch:** the build is ad-hoc signed (free) and therefore not notarized. If macOS blocks it, **right-click → Open** once; subsequent launches work normally. Each build gets a new signature, so macOS may re-ask for folder permissions.

**If you fork:** change `CFBundleIdentifier` in `Info.plist` (`com.jimmy.disktidy`) and the logger subsystem in `TrashService` to your own.

## Design notes

- **`ShellRunner` discards stderr via `FileHandle.nullDevice`.** With a `Pipe`, once the child fills the 64 KB pipe buffer it blocks on write while the parent waits forever reading stdout. `find`'s "Permission denied" output alone exceeds that, and the app really did hang. Covered by a regression test.
- **`DiskScanner.sizes(of:)` batches paths into one `du -sk` call.** Spawning one process per entry means 100+ fork/exec calls for `~/Library/Caches` alone.
- **Six cache tabs share a single `CleanableListViewModel`,** injecting only the scanner closure. Scanning and deletion both run off the main thread, and refresh is guarded against re-entry.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---
Author: JunyoungJung
