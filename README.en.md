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

Nine screens in a sidebar, plus a persistent menu-bar item.

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
| Temp files | Top-level entries in `/private/tmp` and `$TMPDIR` (safety rules and limits below) |

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

## Temp-file safety rules

`/tmp` is a shared directory. Its top level mixes unix sockets, files owned by other users, and markers that are still in use. An entry becomes a deletion candidate only if it passes **all five** rules. Anything that cannot be decided is dropped from the list.

| # | Rule |
|---|---|
| 1 | Owned by me (`st_uid == getuid()`) |
| 2 | Regular file or directory — sockets, FIFOs and symlinks are excluded |
| 3 | **Both** `atime` and `mtime` older than 3 days |
| 4 | Not reported as an open path by `lsof` |
| 5 | Not a root directory itself |

A directory must pass rules 1–4 for its **entire subtree**, not just itself. One socket or one open file anywhere inside removes the whole directory from the list.

Three more guards apply:

- **Mount boundaries are never crossed.** The candidate and every entry below it must share the root's `st_dev`. Renaming a directory that *contains* a mount point succeeds, so without this the recursive delete would reach into the mounted volume.
- **Directories without owner write permission are not candidates.** A `0555` directory can be listed but its children cannot be unlinked. Deletion is not atomic, so it would stop halfway — and the changed mtime then blocks restore as well.
- **Subtree depth is capped at 64.** Beyond that the entry is treated as undecidable and dropped.

### Observation limits

- **Non-root `lsof` cannot fully see file handles held by root or other users' processes.** A file such a process is holding may look closed.
- **`atime` does not prove a recent read.** Filesystems may not update it, so it is never treated as proof of use — only as an additional gate.
- In other words this feature conservatively filters on **state observable from user space only**. Its threat model does not include a hostile process running as the same UID.
- **App Sandbox / Mac App Store distribution is not supported.** Access to `/private/tmp` assumes a directly distributed app with no entitlements.
- If `lsof` or root enumeration fails, the result is an **error**, not an empty list. The list is cleared and a warning banner is shown so the delete button never opens on unverified entries.

## Deletion policy

- App caches, project caches, Xcode caches, large files, Android caches, Android emulators: **moved to Trash** (`FileManager.trashItem`) — recoverable.
- Simulator delete / erase: `xcrun simctl delete` / `erase` — irreversible, so a confirmation dialog is shown first.
- **Temp files: permanent delete.** Moving them to the Trash would not reclaim any disk blocks until the user empties it, which defeats the purpose. Because it is irreversible, a confirmation dialog is always shown. The procedure keeps the scan-time `st_dev + st_ino + uid + mode + mtime + atime`, re-checks it against the parent directory FD right before deletion, atomically moves the entry into a dedicated quarantine directory on the same volume with `renameatx_np(RENAME_EXCL)`, and deletes it only if the identity still matches at the quarantine location. If the app dies mid-move, the quarantined entry shows up in a **pending recovery** list on the next launch and is never removed automatically.
- A successful deletion means "the path was removed". APFS snapshots or open files can delay the free-space increase, so the UI reports the number of deleted paths and the freshly read free space **separately**, and promises no amount reclaimed.
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

**If you fork:** change `CFBundleIdentifier` in `Info.plist` (`com.jimmy.disktidy`) and the logger subsystem in `TrashService`, `PermanentDeleter` and `TempCleanupViewModel` to your own. To notarize, you need an Apple Developer Program membership ($99/year), then `codesign --options runtime --sign "Developer ID Application: ..."` plus `xcrun notarytool submit`.

## Design notes

- **`ShellRunner` discards stderr via `FileHandle.nullDevice`.** With a `Pipe`, once the child fills the 64 KB pipe buffer it blocks on write while the parent waits forever reading stdout. `find`'s "Permission denied" output alone exceeds that, and the app really did hang. Covered by a regression test.
- **`DiskScanner.sizes(of:)` batches paths into one `du -sk` call.** Spawning one process per entry means 100+ fork/exec calls for `~/Library/Caches` alone.
- **Six cache tabs share a single `CleanableListViewModel`,** injecting only the scanner closure. Scanning and deletion both run off the main thread, and refresh is guarded against re-entry.
- **The temp-files tab is the one tab that does not use `CleanableListViewModel`.** `CleanableItem.id` is a fresh `UUID()`, so it does not preserve file identity as of the scan. Using it for an irreversible delete would remove whatever file happens to carry that name at deletion time. `TempCandidate` carries the raw `lstat` values instead, with its own view model and view.
- **`lsof` runs exactly once per scan.** `lsof +D /private/tmp` walks the whole tree and is unusable. `lsof -w -n -F0n -u <uid>` returns every open path for the user's processes as NUL-terminated fields in one shot (measured: 1.2 s, ~89,000 fields). Parsing line by line breaks on filenames containing newlines.
- **Scanning and deletion share one root policy (`TempRootPolicy.production`).** If the two disagreed, every safety rule would collapse, so no API taking a root is exposed to the UI or to callers of the deleter.
- **Path containment compares UTF-8 bytes, not `String.hasPrefix`.** `hasPrefix` works on grapheme clusters, so a filename starting with a combining mark merges with the `/` separator and a real descendant is judged "not a descendant".

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---
Author: JunyoungJung
