# DiskTidy

macOS SSD 용량 정리 유틸리티. 캐시·시뮬레이터·빌드 캐시·대용량 파일을 한 곳에서 훑어보고 정리한다.

[English](README.en.md) · MIT License

<img src="docs/screenshots/01-storage.png" width="820" alt="DiskTidy SSD 용량 화면">

## 화면

| | |
|---|---|
| **캐시데이터** — `~/Library/Caches` 앱별 캐시를 크기순으로<br><img src="docs/screenshots/02-cache.png" width="400" alt="캐시데이터 화면"> | **시뮬레이터** — 오래 방치된 기기가 위로<br><img src="docs/screenshots/03-simulator.png" width="400" alt="시뮬레이터 화면"> |
| **프로젝트 캐시** — 고른 폴더 하위 빌드 캐시 재귀 탐색<br><img src="docs/screenshots/04-project-cache.png" width="400" alt="프로젝트 캐시 화면"> | **대용량 파일** — 200MB 이상 파일 탐색<br><img src="docs/screenshots/06-big-files.png" width="400" alt="대용량 파일 화면"> |
| **Android 캐시** — Gradle · Android Studio<br><img src="docs/screenshots/07-android-cache.png" width="400" alt="Android 캐시 화면"> | **Android 에뮬레이터** — AVD 목록<br><img src="docs/screenshots/08-android-emulator.png" width="400" alt="Android 에뮬레이터 화면"> |

메뉴바 아이콘은 SSD 사용률을 상시 표시하고, 클릭하면 최소 드롭다운이 열린다.

<img src="docs/screenshots/09-menubar.png" width="240" alt="메뉴바 드롭다운">

> 스크린샷은 실제 사용 화면이다. 캐시 항목명·프로젝트 경로 등 개인 정보에 해당하는 부분만 모자이크 처리했다.

## 기능

좌측 사이드바로 이동하는 9개 화면 + 메뉴바 상시 표시.

| 화면 | 내용 |
|---|---|
| SSD 용량 | 전체/사용/여유 용량, 사용률(%) |
| 캐시데이터 | `~/Library/Caches/*` 앱별 캐시 |
| 시뮬레이터 | iOS 시뮬레이터 목록(마지막 사용일 기준 정렬), 기기 삭제 · 데이터 초기화 |
| 프로젝트 캐시 | 사용자가 고른 폴더 하위의 빌드 캐시 재귀 탐색 (판정 규칙은 아래) |
| Xcode 캐시 | `DerivedData` · iOS/watchOS/tvOS DeviceSupport · Archives 전역 스캔 |
| 대용량 파일 | 사용자가 고른 폴더에서 200MB 이상 파일 탐색 (기본값 `~/Downloads`) |
| Android 캐시 | Gradle 캐시/배포판, `~/.android` 캐시, Android Studio IDE 캐시 |
| Android 에뮬레이터 | `~/.android/avd`의 AVD 목록, 삭제 시 `.ini` 포인터까지 정리 |
| 임시파일 | `/private/tmp` · `$TMPDIR`의 최상위 항목 (안전 규칙과 관측 한계는 아래) |

메뉴바 아이콘은 SSD 사용률(%)을 60초마다 갱신해 상시 표시하고, 클릭하면 게이지 + 앱 열기/종료만 뜨는 최소 드롭다운을 보여준다.

## 프로젝트 캐시 판정 규칙

이름만으로 캐시라 단정할 수 있는 디렉터리와, 마커 파일 확인이 필요한 디렉터리를 구분한다.

| 구분 | 디렉터리 | 조건 |
|---|---|---|
| 이름으로 판정 | `Pods` `DerivedData` `.gradle` `Carthage` `.dart_tool` `.next` `.expo` | 없음 |
| 마커 필요 | `node_modules` `dist` | 부모에 `package.json` |
| 마커 필요 | `target` | 부모에 `Cargo.toml` `pom.xml` `build.gradle` `build.gradle.kts` 중 하나 |
| 마커 필요 | `build` | 부모에 `package.json` `build.gradle` `build.gradle.kts` `CMakeLists.txt` `pom.xml` 중 하나 |
| 마커 필요 | `.build` | 부모에 `Package.swift` |

`build` · `dist` · `target`은 커밋된 소스 디렉터리일 수 있어서 마커 없이는 건드리지 않는다. 스캔 루트로 `/` `~` `/Users` 등 지나치게 넓은 경로는 선택할 수 없다.

## 임시파일 안전 규칙

`/tmp`은 공용 디렉터리다. 최상위에 유닉스 소켓·타 사용자 소유 파일·아직 쓰이는 마커가 섞여 있어서, 항목 하나를 후보로 올리려면 아래 5개를 **모두** 통과해야 한다. 하나라도 판정할 수 없으면 후보에서 뺀다.

| # | 규칙 |
|---|---|
| 1 | 소유자가 나 (`st_uid == getuid()`) |
| 2 | 정규 파일 또는 디렉터리 — 소켓·FIFO·심볼릭 링크 제외 |
| 3 | `atime`과 `mtime`이 **둘 다** 3일 초과 |
| 4 | `lsof` 스냅샷에 열린 경로로 잡히지 않음 |
| 5 | 루트 디렉터리 자체가 아님 |

디렉터리는 자신뿐 아니라 **하위 트리 전체**가 규칙 1~4를 통과해야 한다. 안에 소켓 하나, 열린 파일 하나만 있어도 디렉터리째 후보에서 빠진다.

여기에 세 가지를 더 막는다.

- **마운트 경계를 넘지 않는다.** 후보와 하위 항목의 `st_dev`가 루트와 같아야 한다. 마운트 포인트를 품은 디렉터리는 이동이 성공하므로, 막지 않으면 재귀 삭제가 마운트된 볼륨 내용까지 지운다.
- **쓰기 권한 없는 디렉터리는 후보가 아니다.** `0555` 디렉터리는 열거만 되고 자식 삭제는 실패한다. 삭제는 원자적이지 않아 일부만 지운 채 멈추고, 그 시점에 복원까지 막힌다.
- **하위 트리 깊이 상한은 64.** 넘으면 판정 불가로 보고 제외한다.

### 관측 한계

- **`lsof`는 root·다른 사용자 프로세스의 파일 핸들을 완전하게 보지 못한다.** 그 프로세스가 붙잡고 있는 파일은 "열려 있지 않음"으로 보일 수 있다.
- **`atime`은 최근 읽기를 증명하지 못한다.** 파일시스템의 갱신 정책에 따라 갱신되지 않을 수 있어서, 사용 중 증명으로 취급하지 않고 보조 조건으로만 쓴다.
- 즉 이 기능은 **사용자 공간에서 관찰 가능한 상태만 보수적으로** 거른다. 위협 모델에 같은 UID의 적대 프로세스는 포함하지 않는다.
- **App Sandbox / Mac App Store 배포는 지원하지 않는다.** entitlement 없는 직접 배포 앱을 전제로 `/private/tmp`에 접근한다.
- `lsof` 실행이나 루트 열거에 실패하면 빈 목록이 아니라 **오류**로 처리한다. 목록을 비우고 경고 배너를 띄워서, 검증되지 않은 항목에 삭제 버튼이 열리지 않게 한다.

## 삭제 정책

- 캐시데이터 · 프로젝트 캐시 · Xcode 캐시 · 대용량 파일 · Android 캐시 · Android 에뮬레이터: **휴지통으로 이동** (`FileManager.trashItem`) — 복구 가능.
- 시뮬레이터 기기 삭제/초기화: `xcrun simctl delete` / `erase` — 되돌릴 수 없어서 실행 전 확인 다이얼로그를 띄운다.
- **임시파일: 완전 삭제** — 휴지통을 거치면 사용자가 비우기 전까지 디스크 블록이 회수되지 않아서 tmp 탭에는 맞지 않는다. 되돌릴 수 없으므로 확인 다이얼로그를 반드시 거친다. 삭제 절차는 스캔 시점의 `st_dev + st_ino + uid + mode + mtime + atime`을 보존했다가, 삭제 직전 부모 디렉터리 FD 기준으로 같은 파일인지 다시 확인하고 → 같은 볼륨 안의 전용 격리 디렉터리로 `renameatx_np(RENAME_EXCL)` 원자 이동 → 격리 위치에서 동일성이 유지될 때만 지운다. 도중에 앱이 죽으면 격리 항목이 다음 실행의 **복구 대기 목록**에 뜨고, 자동으로 지우지 않는다.
- 삭제 성공은 "경로를 삭제했다"는 뜻이다. APFS 스냅샷이나 열린 파일 때문에 여유 용량 증가가 지연될 수 있어서, 화면은 삭제한 경로 수와 새로 읽은 여유 용량을 **따로** 보여 주고 회수량을 약속하지 않는다.
- 삭제 실패(권한 부족, 사용 중인 파일, 부팅 중인 시뮬레이터)는 화면에 경고 배너로 보고하고 목록에서 지우지 않는다. 상세 원인은 Console.app에서 `com.jimmy.disktidy` 로그로 확인한다.

## 요구사항

- macOS 13 이상
- Xcode 16 이상 (Swift Testing 사용)
- 첫 실행 시 `~/Documents`, `~/Downloads` 등 접근에 대한 macOS 파일 접근 권한(TCC) 승인 필요

## 실행

```bash
./Scripts/run.sh          # 개발 모드 (release 빌드 후 즉시 실행, Dock 아이콘 뜸)
swift test                # 테스트
```

## 설치

### 내려받아 설치 (DMG)

**1단계.** [Releases](../../releases)에서 `DiskTidy-<version>.dmg`를 받아 열고 `DiskTidy.app`을 `Applications`로 끌어다 놓는다.

<img src="docs/screenshots/10-install-dmg.png" width="600" alt="DMG를 열어 DiskTidy.app을 Applications로 드래그">

무결성 확인:

```bash
shasum -a 256 -c DiskTidy-1.0.dmg.sha256
```

### 소스에서 빌드

```bash
./Scripts/build-app.sh    # release 빌드 → DiskTidy.app → ~/Applications 설치
./Scripts/make-dmg.sh     # release 빌드 → dist/DiskTidy-<version>.dmg + .sha256
./Scripts/make-app.sh     # DiskTidy.app 번들만 (설치·배포 안 함)
```

`Info.plist`의 `LSUIElement=true` 때문에 설치된 `.app`은 Dock 아이콘 없이 메뉴바로만 상주한다 (개발 모드 `run.sh`는 영향 없음).

### 첫 실행 (Gatekeeper)

이 앱은 **ad-hoc 서명(무료)이라 Apple 공증을 받지 않았다.** 처음 열면 macOS가 아래 경고를 띄우며 차단한다. 정상이다.

<img src="docs/screenshots/11-install-gatekeeper.png" width="260" alt="Gatekeeper 차단 경고: 'DiskTidy'을(를) 열지 않음">

> **휴지통으로 이동을 누르지 말 것.** `완료`를 누르고 아래 절차를 따른다.

**macOS 15 Sequoia 이상** — Apple이 우클릭 → 열기 우회를 제거했다. 다음 순서로 허용한다:

1. `DiskTidy.app`을 한 번 실행 → 차단 경고가 뜨면 닫는다
2. **시스템 설정 → 개인정보 보호 및 보안** 으로 이동
3. 아래로 스크롤해 DiskTidy 항목의 **"확인 없이 열기"** 를 누른다

**macOS 13~14** — `DiskTidy.app`을 **우클릭 → 열기** 로 한 번 실행하면 이후에는 그냥 열린다.

**터미널로 처리** (개발자용, 어느 버전이든 동작):

```bash
xattr -dr com.apple.quarantine /Applications/DiskTidy.app
```

서명을 신뢰하기 전에 직접 확인하려면:

```bash
codesign -dv --verbose=4 /Applications/DiskTidy.app
```

빌드마다 ad-hoc 서명이 새로 생성되므로, 재설치 후 macOS가 폴더 접근 권한(TCC)을 다시 물어볼 수 있다.

**포크한다면:** `Info.plist`의 `CFBundleIdentifier`(`com.jimmy.disktidy`)와 `TrashService`·`PermanentDeleter`·`TempCleanupViewModel`의 로거 subsystem을 본인 것으로 바꿀 것. 공증까지 하려면 Apple Developer Program($99/년) 가입 후 `codesign --options runtime --sign "Developer ID Application: ..."` + `xcrun notarytool submit`이 필요하다.

## 앱 아이콘 재생성

```bash
./Scripts/generate-icon.sh
```

`Scripts/generate-icon.swift`(AppKit으로 SF Symbol 기반 1024px PNG 렌더링) → `sips`로 각 해상도 생성 → `iconutil`로 `Resources/AppIcon.icns` 패킹까지 한 번에 처리한다. 디자인을 바꾸려면 `generate-icon.swift`의 배경색·SF Symbol 이름을 수정한 뒤 다시 실행한다.

## 폴더 구조

```
DiskTidy/
  Package.swift
  Info.plist
  LICENSE                  # MIT
  README.md / README.en.md
  CONTRIBUTING.md
  .github/workflows/
    ci.yml                 # 빌드 + 테스트 + 경고 0건 검사
    release.yml            # v* 태그 push 시 DMG 빌드 + 릴리스 첨부
  docs/screenshots/        # README용 스크린샷
  Resources/
    AppIcon-1024.png       # 아이콘 소스 PNG
    AppIcon.icns           # 앱에 실제 포함되는 아이콘
    AppIcon.iconset/       # 중간 산출물 (git 제외, generate-icon.sh가 재생성)
  Scripts/
    run.sh                 # 개발 모드 실행
    make-app.sh            # DiskTidy.app 번들 생성 (아래 둘이 공유)
    build-app.sh           # make-app.sh + ~/Applications 설치
    make-dmg.sh            # make-app.sh + dist/DiskTidy-<version>.dmg + .sha256
    generate-icon.sh       # 아이콘 전체 파이프라인
    generate-icon.swift    # 아이콘 PNG 렌더러
  dist/                    # DMG 산출물 (git 제외)
  Sources/DiskTidy/
    DiskTidyApp.swift      # @main, WindowGroup + MenuBarExtra
    Models/                # CleanableItem, TempCandidate, SimulatorItem, StorageSnapshot,
                           #   AppNavigationState
    Services/              # 스캐너 + 공용 헬퍼(ShellRunner, DiskScanner, TrashService,
                           #   RootFolderStore, FileAttributes, StorageInfo, StorageMonitor)
                           #   + 임시파일 전용(TempRootPolicy, TempScanner, PermanentDeleter)
    ViewModels/            # CleanableListViewModel(전 캐시 탭 공용), SimulatorViewModel,
                           #   RootFolderViewModel, TempCleanupViewModel
    Views/                 # ContentView(사이드바) + 화면별 탭 뷰 +
                           #   공용 컴포넌트(CleanableListView, RootFolderPicker, ErrorBanner)
  Tests/DiskTidyTests/     # Swift Testing
```

## 설계 메모

- **`ShellRunner`는 stderr를 `FileHandle.nullDevice`로 버린다.** `Pipe`로 두면 자식이 파이프 버퍼(64KB)를 채운 순간 write에서 블록되고 부모는 stdout 읽기에서 영구 대기한다. `find`의 `Permission denied` 출력만으로도 넘는 양이라 실제로 앱이 멈췄다. 회귀 테스트 있음.
- **`DiskScanner.sizes(of:)`는 `du -sk`에 경로를 묶어 넘긴다.** 엔트리마다 프로세스를 띄우면 `~/Library/Caches`(100개 이상)에서만 100번 넘게 fork/exec 한다.
- **캐시 탭 6개가 `CleanableListViewModel` 하나를 공유한다.** 스캐너 클로저만 주입한다. 스캔·삭제는 모두 백그라운드에서 돌고, 새로고침 재진입은 가드로 막는다.
- **임시파일 탭만 `CleanableListViewModel`을 쓰지 않는다.** `CleanableItem`의 `id`는 `UUID()`라 스캔 시점의 파일 동일성을 보존하지 않는다. 되돌릴 수 없는 삭제에 쓰면 스캔과 삭제 사이에 이름이 바뀐 다른 파일을 지운다. 그래서 `TempCandidate`가 `lstat` 값을 그대로 들고 다니고, 전용 ViewModel·View를 따로 둔다.
- **`lsof`는 스캔당 한 번만 부른다.** `lsof +D /private/tmp`는 트리를 전수 순회해서 못 쓴다. `lsof -w -n -F0n -u <uid>`로 사용자 프로세스 전체의 열린 경로를 NUL 종료 필드로 한 번에 받는다(실측 1.2초, 약 89,000 필드). 줄 단위로 파싱하면 줄바꿈이 든 파일명에서 필드가 깨진다.
- **스캔과 삭제가 같은 루트 정책(`TempRootPolicy.production`)을 쓴다.** 둘이 다른 판정을 하면 안전 규칙이 통째로 무너지므로, UI·삭제 호출부에는 루트를 받는 API를 아예 만들지 않았다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md) 참고.

---
Author: JunyoungJung
