# DiskTidy

macOS SSD 용량 정리 유틸리티. 캐시·시뮬레이터·빌드 캐시·대용량 파일을 한 곳에서 훑어보고 정리한다.

[English](README.en.md) · MIT License

## 기능

좌측 사이드바로 이동하는 8개 화면 + 메뉴바 상시 표시.

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

## 삭제 정책

- 캐시데이터 · 프로젝트 캐시 · Xcode 캐시 · 대용량 파일 · Android 캐시 · Android 에뮬레이터: **휴지통으로 이동** (`FileManager.trashItem`) — 복구 가능.
- 시뮬레이터 기기 삭제/초기화: `xcrun simctl delete` / `erase` — 되돌릴 수 없어서 실행 전 확인 다이얼로그를 띄운다.
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

[Releases](../../releases)에서 `DiskTidy-<version>.dmg`를 받아 열고 `DiskTidy.app`을 `Applications`로 끌어다 놓는다.

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

이 앱은 **ad-hoc 서명(무료)이라 Apple 공증을 받지 않았다.** 처음 열면 macOS가 차단한다.

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

**포크한다면:** `Info.plist`의 `CFBundleIdentifier`(`com.jimmy.disktidy`)와 `TrashService`의 로거 subsystem을 본인 것으로 바꿀 것. 공증까지 하려면 Apple Developer Program($99/년) 가입 후 `codesign --options runtime --sign "Developer ID Application: ..."` + `xcrun notarytool submit`이 필요하다.

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
  .github/workflows/ci.yml # 빌드 + 테스트 + 경고 0건 검사
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
    Models/                # CleanableItem, SimulatorItem, StorageSnapshot, AppNavigationState
    Services/              # 스캐너 + 공용 헬퍼(ShellRunner, DiskScanner, TrashService,
                           #   RootFolderStore, FileAttributes, StorageInfo, StorageMonitor)
    ViewModels/            # CleanableListViewModel(전 캐시 탭 공용), SimulatorViewModel,
                           #   RootFolderViewModel
    Views/                 # ContentView(사이드바) + 화면별 탭 뷰 +
                           #   공용 컴포넌트(CleanableListView, RootFolderPicker, ErrorBanner)
  Tests/DiskTidyTests/     # Swift Testing
```

## 설계 메모

- **`ShellRunner`는 stderr를 `FileHandle.nullDevice`로 버린다.** `Pipe`로 두면 자식이 파이프 버퍼(64KB)를 채운 순간 write에서 블록되고 부모는 stdout 읽기에서 영구 대기한다. `find`의 `Permission denied` 출력만으로도 넘는 양이라 실제로 앱이 멈췄다. 회귀 테스트 있음.
- **`DiskScanner.sizes(of:)`는 `du -sk`에 경로를 묶어 넘긴다.** 엔트리마다 프로세스를 띄우면 `~/Library/Caches`(100개 이상)에서만 100번 넘게 fork/exec 한다.
- **캐시 탭 6개가 `CleanableListViewModel` 하나를 공유한다.** 스캐너 클로저만 주입한다. 스캔·삭제는 모두 백그라운드에서 돌고, 새로고침 재진입은 가드로 막는다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md) 참고.

---
Author: JunyoungJung
