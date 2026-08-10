# 메모리 정리 (개발 데몬 정리) 개발 문서

- 작성자: JunyoungJung
- 작성일: 2026-08-07
- 대상 버전: DiskTidy 1.2.0 (현재 `Info.plist` 1.0.1, 임시파일 정리 1.1.0 다음 릴리스)
- 상태: 구현 완료 (2026-08-10). 4절 `JavaMainClassParser`의 허용 옵션 목록은 실측에 맞춰 확장했다 — 최종 구현은 `Sources/DiskTidy/Models/RunningProcess.swift` 참조
- 관련 문서: [temp-cleanup.md](temp-cleanup.md) — 독립 기능이지만 위험도가 낮아 그쪽을 먼저 넣는다

---

## 1. 배경과 기능 재정의

"메모리 정리"를 요청받았지만, **macOS에서 통상 말하는 메모리 정리(`purge`)는 이 문제를 해결하지 못한다.** 먼저 그 사실부터 확정하고 시작한다.

### `purge`를 쓰지 않는 이유

```
$ ls -l /usr/sbin/purge
-rwxr-xr-x  1 root  wheel  100800 Jun 25 11:29 /usr/sbin/purge
```

- 일반 사용자 실행은 권한 오류가 난다. root 소유·setuid 비트만으로 판단하지 않고 실제 실행 결과를 기준으로 한다.
- 하는 일은 **파일시스템 디스크 캐시(UBC) 플러시**뿐이다. 앱 메모리도, 압축 메모리도, 스왑도 건드리지 않는다.
- 효과는 Activity Monitor의 "캐시된 파일" 숫자가 내려가는 것. 대신 다음 파일 읽기가 디스크까지 내려가 느려진다.
- 스왑 39GB가 찬 상태에서 실질 회수량 ≒ 0.

관리자 인증 다이얼로그를 띄워 놓고 아무것도 회수하지 못하는 버튼은 만들지 않는다.

### 실제로 RAM을 되찾는 건 프로세스 종료

실측 (2026-08-07, 24GB RAM, 무중단 가동 중):

| 지표 | 값 |
|---|---|
| `kern.memorystatus_vm_pressure_level` | **2** (warning) |
| 여유 메모리 | 28% |
| 스왑 사용 | **39.6 GB / 40.9 GB** |

메모리를 물고 있던 장기 실행 개발 프로세스:

| 프로세스 | 근거 |
|---|---|
| `GradleDaemon 8.13` | `-Xmx4g` |
| `KotlinCompileDaemon` | `-Xmx4g`, `--daemon-autoshutdownIdleSeconds=7200` (2시간 유휴 생존) |
| node MCP 서버 10개 이상 | context7, playwright, chrome-devtools, github, memory, axiom … |
| VS Code Renderer | 336MB / 255MB / 165MB |
| `xcodebuild` | 161MB |
| 시뮬레이터 런타임 프로세스 | iOS 18.6 위젯 익스텐션 등이 잔류 |

→ 기능 이름을 **"개발 데몬 정리"** 로 정하고, 메모리·스왑 지표는 판단 근거로 같은 탭에 표시한다.

### 스왑은 정리 대상이 아니다 (표시만)

```
$ ls -lh /System/Volumes/VM
-rw-------  1 root  wheel  1.0G  swapfile0
...
-rw-------  1 root  wheel  1.0G  swapfile40      ← 41개

$ df -h /System/Volumes/VM
/dev/disk3s6   460Gi   41Gi   41Gi   51%   /System/Volumes/VM
```

- 스왑 파일은 별도 APFS 볼륨(`disk3s6`)에 있고 전부 `root:wheel 0600`이며 OS가 관리한다. `/sbin/dynamic_pager`가 존재할 수 있지만 그 동작·파일 수명은 앱의 계약이 아니다. DiskTidy는 이를 호출하거나 스왑 파일을 조작하지 않는다.
- 사용 중 삭제·이름 변경·크기 조절은 하지 않는다. root 권한으로 지워도 시스템이 불안정해질 수 있다.
- `swapfile*` 합계는 **현재 시점의 할당 관측값**일 뿐, 사용자가 즉시 되찾을 수 있는 바이트 수가 아니다. macOS는 VM 수요에 따라 파일을 유지·확장·회수할 수 있다. 프로세스 종료나 재시동은 압박을 낮출 수 있지만 정확히 N GB가 회수된다고 보장하지 않는다.
- VM 볼륨은 `/`와 같은 APFS 컨테이너를 공유하므로 현재 할당은 관측 여유 용량에 영향을 준다. 다만 `swapfile*` 합계와 이후 여유 용량 변화가 1:1이라고 표시하지 않고, `StorageInfo`의 새 측정값만 보여 준다.
- hibernation 관련 파일도 건드리지 않는다. Apple Silicon에서 `hibernatemode` 조작은 절전 동작을 깨뜨릴 수 있다.

→ 스왑 섹션은 **읽기 전용**. 임계치 초과 시 “스왑 사용량이 높습니다. 프로세스 종료 후에도 여유 용량이 바로 늘지 않을 수 있습니다. 상태가 지속되면 재시동을 고려하세요.”를 안내한다. 삭제 버튼 없음.

## 2. 목표 / 비목표

**목표**
- 메모리 압박·스왑 상태를 한 화면에서 정확히 보여준다.
- 장기 실행 개발 데몬을 식별해 안전하게 종료하고 RAM을 회수한다.
- 시뮬레이터 일괄 종료를 원클릭으로 제공한다.

**비목표**
- `purge` 실행 — 1절 참조.
- 스왑 파일 삭제 — 1절 참조.
- 자동/주기 종료 — 저장하지 않은 작업이 날아간다. 수동 확인만.
- 정확한 프로세스 메모리 풋프린트 — root 권한이 필요하다. RSS 근사치로 간다 (5절).
- App Sandbox / Mac App Store 배포 지원 — 현재 기능은 entitlement 없는 직접 배포 앱을 전제로 한다. 샌드박스 배포가 목표가 되면 프로세스 조회·시그널·VM 볼륨 접근부터 다시 설계한다.

## 3. 메모리·스왑 지표 수집

기본 수집은 셸 없이 Darwin API로 읽는다. `xsw_usage`를 가져올 수 없는 빌드 대상에서만 3.3절의 문자열 파서를 fallback으로 쓴다. 각 수집 실패는 0으로 바꾸지 않고 `MemoryInfo.Error`로 보존해 UI가 "측정 불가"를 표시한다.

```swift
enum MemoryInfo {
    enum Error: Swift.Error, Equatable {
        case hostStatistics(kern_return_t)
        case swapUsage(Int32)
        case vmDirectory(Int32)
    }
}
```

### 3.1 물리 메모리 — `host_statistics64`

```swift
import Darwin

var stats = vm_statistics64_data_t()
var count = mach_msg_type_number_t(
    MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
)
let result = withUnsafeMutablePointer(to: &stats) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
    }
}
guard result == KERN_SUCCESS else { throw MemoryInfo.Error.hostStatistics(result) }

let pageSize = Int64(vm_kernel_page_size)   // 이 머신에서 16384
```

Activity Monitor 항목 대응 (근사):

| 표시 항목 | 계산식 |
|---|---|
| 앱 메모리 | `(internal_page_count - purgeable_count) * pageSize` |
| 통합 메모리 (Wired) | `wire_count * pageSize` |
| 압축됨 | `compressor_page_count * pageSize` |
| 캐시된 파일 | `(external_page_count + purgeable_count) * pageSize` |
| 여유 | `(free_count + speculative_count) * pageSize` |

전체 물리 메모리는 `sysctlbyname("hw.memsize")`로 따로 읽는다.

### 3.2 메모리 압박

```swift
sysctlbyname("kern.memorystatus_vm_pressure_level", ...)  // 1 정상 / 2 경고 / 4 위험
```

UI에서 1=녹색 / 2=주황 / 4=빨강. 2 이상이면 데몬 정리 섹션을 강조한다.

### 3.3 스왑 — `vm.swapusage`

```swift
var usage = xsw_usage()
var size = MemoryLayout<xsw_usage>.stride
if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) != 0 {
    let errorCode = errno
    throw MemoryInfo.Error.swapUsage(errorCode)
}
// usage.xsu_total, xsu_used, xsu_avail (UInt64), xsu_encrypted (Bool)
```

> **현재 확인**: 현 Xcode/macOS 환경에서는 `import Darwin` + `xsw_usage` + `sysctlbyname("vm.swapusage", ...)`가 컴파일·실행됐다. macOS 13/Intel 실기 스모크 테스트도 추가한다. 빌드 대상에서 타입을 가져올 수 없거나 sysctl 호출이 실패할 때만 아래 문자열 파서로 대체하며, 어느 경로든 실패는 0값이 아니라 측정 불가 상태로 표시한다.
>
> ```
> $ sysctl -n vm.swapusage
> total = 40960.00M  used = 39653.88M  free = 1306.12M  (encrypted)
> ```

### 3.4 스왑 파일이 점유한 SSD 용량

```swift
// /System/Volumes/VM 의 swapfile* 크기 합.
// 파일은 root:wheel 0600이지만 디렉터리는 읽을 수 있고 stat도 통과한다 (실측 확인).
FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Volumes/VM"), ...)
    .filter { $0.lastPathComponent.hasPrefix("swapfile") }
```

이 값이 임계치(기본 8GB)를 넘으면 안내 배너를 띄운다. 디렉터리 열거·`stat` 권한이 실패하면 이 섹션만 측정 불가로 표시하고, 0GB 또는 스왑 없음으로 보이지 않게 한다. 이 수치는 현재 할당량이므로 회수 가능 용량으로 표기하지 않는다.
> 스왑 파일이 현재 41GB를 사용 중입니다. 프로세스 종료 후에도 여유 용량이 바로 늘지 않을 수 있습니다. 상태가 지속되면 재시동을 고려하세요.

## 4. 프로세스 수집과 동일성

`/bin/ps`는 후보 PID와 RSS만 찾는 용도다. **argv·종료 권한·동일성 판단은 `ps` 문자열에 의존하지 않는다.** PID는 `ps`가 반환한 직후 재사용될 수 있으므로, `ps`의 옛 argv와 Darwin API로 읽은 새 identity를 한 `RunningProcess`에 합치면 안 된다. Gradle·Kotlin 분류에 필요한 argv는 `KERN_PROCARGS2`로 읽고, UID·실행 경로·시작 시각은 `import Darwin`의 `proc_pidinfo`/`proc_pidpath` C API로 읽는다. 별도 `import libproc` 모듈은 없다.

```
/bin/ps -U <uid> -o pid=,rss=
```

- `-U <uid>`로 후보를 줄이되 `ps`의 UID도 신뢰 경계가 아니다. `proc_pidinfo`로 UID를, `proc_pidpath`로 실제 실행 경로를 다시 읽는다.
- `ps`의 RSS는 표시용 근사치다. PID가 바뀌면 다음 갱신에서 정정될 수 있으나, 분류·시그널 판단에는 쓰지 않는다.
- `/bin/ps` 실행 실패·비정상 종료·파싱 오류는 빈 목록이 아니라 `ProcessScanner.Error`다. UI는 이전 선택을 버리고 오류 배너를 보인다.
- `rss=`는 KB 단위다.

`proc_pidpath`/`proc_pidinfo`는 현재 `Darwin` 임포트에서 동작을 확인했다. Swift importer가 `PROC_PIDPATHINFO_MAXSIZE` 매크로를 노출하지 않으므로 `4 * Int(PATH_MAX)` 크기의 `[CChar]` 버퍼를 명시적으로 사용한다. 반환 크기와 `proc_pidinfo` 결과 크기를 모두 확인하며, `pbi_uid`, `pbi_start_tvsec`, `pbi_start_tvusec`를 identity로 보존한다.

`KERN_PROCARGS2` argv는 다음 순서를 지켜 identity에 결합한다.

1. PID의 identity A를 `proc_pidinfo`/`proc_pidpath`로 읽는다.
2. `sysctl([CTL_KERN, KERN_PROCARGS2, pid], ...)`에서 길이를 확인한 뒤 argv를 파싱한다. argc·NUL 경계·최대 크기·UTF-8 오류를 검증하고, 불완전하면 실패다.
3. 같은 PID의 identity B를 다시 읽는다. A == B일 때만 argv를 채택해 분류한다.

그 사이 identity가 달라지거나 argv를 읽을 수 없으면 해당 PID는 종료 후보가 아니다. argv를 비워 `.activeWorkload`로 표시하거나 목록에서 제외하며, 추측으로 `.devDaemon`을 만들지 않는다.

> **현재 확인**: 현 Xcode/macOS 환경에서 `KERN_PROCARGS2` 상수가 `Darwin`에 노출되고, 자기 PID의 길이 조회와 argv 버퍼 조회가 모두 성공했다. macOS 13/Intel 실기에서도 같은 스모크 테스트를 하며, 어느 대상에서든 실패하면 그 프로세스는 종료 불가로 처리한다.

```swift
import Darwin
import Foundation

enum DevDaemon: String, Hashable {
    case gradle, kotlin
}

enum ProcessKind: Hashable {
    case devDaemon(DevDaemon)             // identity-bound argv 검증 뒤에만 수동 종료 가능
    case activeWorkload(String)            // 표시만, 종료 불가
    case protected(String)                 // 표시하지 않음
    case userApp                           // 표시하지 않음
}

struct ProcessStartTime: Hashable {
    let seconds: Int64
    let microseconds: Int32
}

struct ProcessIdentity: Hashable {
    let pid: Int32
    let uid: uid_t
    let startTime: ProcessStartTime
    let executablePath: String
    /// `proc_pidpath`가 돌려준 실제 경로에서만 만든 basename. argv/displayName은 쓰지 않는다.
    let executableName: String
}

struct RunningProcess: Identifiable, Hashable {
    let id: Int32                          // identity.pid
    let identity: ProcessIdentity
    let residentBytes: Int64
    let arguments: [String]                // identity A → KERN_PROCARGS2 → identity B 검증 후 값
    let displayName: String                // 표시용; 종료 정책에는 쓰지 않음
    let kind: ProcessKind
    var isSelected: Bool = false

    var isTerminable: Bool {
        TerminationPolicy.canTerminate(
            identity: identity, kind: kind, arguments: arguments
        )
    }
}

enum JavaMainClassParser {
    /// Gradle/Kotlin 데몬에서 확인한 launcher option만 허용한다.
    /// 알 수 없는 option은 main class로 추측하지 않고 nil을 반환한다.
    ///
    /// **구현 시 실측 보정**: Gradle 8.13은 `--add-opens=…`·`--add-exports=…`·`-javaagent:…`를,
    /// Kotlin 2.2.21 데몬은 `--add-exports`를 **분리형**으로 쓰고 `-ea`·`-XX:…`도 낀다.
    /// 아래 목록만으로는 두 데몬 모두 nil이 되어 종료 후보가 하나도 생기지 않는다.
    /// 실제 허용 목록은 `Sources/DiskTidy/Models/RunningProcess.swift`에 있다.
    private static let optionsWithValue: Set<String> = [
        "-cp", "-classpath", "--class-path"
    ]

    static func mainClass(from arguments: [String]) -> String? {
        var index = 1 // argv[0]은 실제 java 실행 파일
        while index < arguments.count {
            let argument = arguments[index]
            if optionsWithValue.contains(argument) {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else { return nil }
                index = valueIndex + 1
                continue
            }
            if argument.hasPrefix("--class-path=") ||
                argument.hasPrefix("-D") ||
                argument.hasPrefix("-X") ||
                argument.hasPrefix("-XX:") {
                index += 1
                continue
            }
            guard !argument.hasPrefix("-") else { return nil }
            return argument
        }
        return nil
    }
}

enum TerminationPolicy {
    private static let protectedPathPrefixes = [
        "/System", "/usr/libexec", "/usr/sbin", "/usr/bin", "/Library/Apple"
    ]
    private static let protectedNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "ControlCenter", "coreaudiod", "DiskTidy"
    ]

    static func canTerminate(
        identity: ProcessIdentity,
        kind: ProcessKind,
        arguments: [String],
        currentUID: uid_t = getuid(),
        currentPID: Int32 = getpid(),
        parentPID: Int32 = getppid()
    ) -> Bool {
        guard case .devDaemon = kind,
              identity.uid == currentUID,
              identity.pid != 1,
              identity.pid != currentPID,
              identity.pid != parentPID,
              !isProtectedPath(identity.executablePath),
              !protectedNames.contains(identity.executableName),
              identity.executableName == "java",
              hasExpectedMainClass(arguments, for: kind)
        else { return false }
        return true
    }

    private static func isProtectedPath(_ path: String) -> Bool {
        protectedPathPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func hasExpectedMainClass(
        _ arguments: [String], for kind: ProcessKind
    ) -> Bool {
        let expectedMainClass: String
        switch kind {
        case .devDaemon(.gradle):
            expectedMainClass = "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
        case .devDaemon(.kotlin):
            expectedMainClass = "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"
        case .activeWorkload, .protected, .userApp:
            return false
        }
        return JavaMainClassParser.mainClass(from: arguments) == expectedMainClass
    }
}
```

`executableName`은 `proc_pidpath`의 유효한 반환값에서 `URL(fileURLWithPath:).lastPathComponent`으로 만든다. `displayName`·`ps` 출력은 종료 정책에 쓰지 않는다. `.devDaemon`은 identity-bound argv에서 `JavaMainClassParser`가 반환한 **실제 main class**가 정확히 일치하고 실제 실행 파일명이 `java`일 때만 만든다. 알 수 없는 Java launcher option은 종료 불가로 처리한다. UI의 `isTerminable`와 `ProcessTerminator`는 이 **하나의 순수 정책**을 공유하며, 종료기는 identity와 argv를 다시 읽은 뒤에도 같은 정책을 다시 적용한다.

종료기는 scan-time `arguments`를 직접 받지 않고 아래 재검증 결과만 사용한다.

```swift
enum ProcessScanner {
    enum Revalidation {
        case verified(identity: ProcessIdentity, arguments: [String], kind: ProcessKind)
        case identityChanged
        case daemonEvidenceUnavailable
    }

    /// identity A → KERN_PROCARGS2 → identity B를 수행한다.
    /// A == B == expected일 때만 .verified를 반환한다.
    static func revalidate(matching expected: ProcessIdentity) -> Revalidation
}
```

### 분류·표시·종료 정책

문자열 첫 일치만으로 모든 앱을 종료 후보로 만들지 않는다. 실제 실행 경로가 시스템 차단 경로면 항상 `.protected`이며, 나머지도 아래 정책을 따른다.

| 분류 | 판정 | UI/종료 정책 |
|---|---|---|
| Gradle 데몬 | identity-bound `KERN_PROCARGS2` argv에서 파싱한 실제 main class가 `org.gradle.launcher.daemon.bootstrap.GradleDaemon` + 실제 실행 파일명 `java` | `.devDaemon`, 수동 선택 후 종료 가능 |
| Kotlin 컴파일 데몬 | identity-bound `KERN_PROCARGS2` argv에서 파싱한 실제 main class가 `org.jetbrains.kotlin.daemon.KotlinCompileDaemon` + 실제 실행 파일명 `java` | `.devDaemon`, 수동 선택 후 종료 가능 |
| MCP 서버 | node 실행 경로 + 명시적으로 식별 가능한 서버 엔트리포인트 | `.activeWorkload`, 상태만 표시하고 이 릴리스에서는 종료 불가. 문자열 추측으로 시그널을 보내지 않음 |
| SourceKit·`swift-frontend`·XCBBuildService·Dart/Flutter | 실제 빌드/인덱싱/실행 중인 작업 | `.activeWorkload`, 상태만 표시하고 이 탭에서 종료 불가 |
| CoreSimulator·Android emulator | 런타임 프로세스 | `.activeWorkload`, 시뮬레이터는 7절 액션으로만 종료 |
| 일반 `/Applications` 앱 | 위 조건 불일치 | `.userApp`, 목록에서 제외 |

`TerminationPolicy`는 `.devDaemon` 분류 외에 현재 UID·PID 1·DiskTidy 자신·부모·시스템 차단 경로·차단 이름을 모두 확인한다. 이 조건은 목록 표시를 위한 `.protected` 분류와 별개로, UI와 실제 시그널 전송이 공통으로 통과해야 하는 최종 게이트다.

## 5. RSS는 근사치다 — UI에 명시할 것

`ps`의 RSS는 Apple Silicon에서 실제 메모리 사용량과 다르다.

- 압축된 페이지가 반영되지 않는다.
- 공유 라이브러리 페이지가 프로세스마다 중복 계산된다.
- 따라서 전체 RSS 합계가 물리 메모리를 초과할 수 있다.

정확한 풋프린트는 `footprint(1)`이 주지만 root가 필요하다. UI에 **"근사치"** 라벨을 붙이고, "이만큼 회수됩니다"가 아니라 "이 프로세스가 크다"는 정렬 기준으로만 쓴다.

## 6. 프로세스 종료 — 동일성 재검증이 본체

> 프로세스 종료는 되돌릴 수 없고 저장하지 않은 작업이 사라진다. 목록에 있던 PID가 확인창을 보는 동안 다른 프로세스에 재사용될 수 있으므로, **스캔 시점 정보만으로 시그널을 보내면 안 된다.**

1. 종료 가능 대상은 `TerminationPolicy.canTerminate(...) == true`인 명시적 `.devDaemon`뿐이다. 일반 앱·활성 빌드·런타임·보호 프로세스에는 종료 버튼을 만들지 않는다.
2. 종료 직전 `ProcessScanner`가 identity A를 다시 읽어 scan-time identity와 비교하고, `KERN_PROCARGS2` argv를 읽은 뒤 identity B를 다시 읽는다. A == B == scan-time identity가 아니면 `.refused(.identityChanged)`다. argv가 불완전하거나 읽히지 않으면 `.refused(.daemonEvidenceChanged)`이며, 어느 경우도 시그널을 보내지 않는다.
3. 2절에서 새로 분류한 kind와 argv를 같은 `TerminationPolicy.canTerminate(identity:kind:arguments:)`에 넣는다. scan-time kind/argv만 재사용하거나 UI와 종료기의 조건을 따로 구현하지 않는다.
4. `SIGTERM`을 먼저 보내고 3초 동안 50ms 간격으로 확인한다. 살아 있고 identity A → argv → identity B 재검증과 `TerminationPolicy`를 다시 통과할 때만 `SIGKILL`로 올린다. 곧바로 SIGKILL을 보내면 Gradle 데몬이 락 파일을 남겨 다음 빌드가 실패할 수 있다.
5. `kill(pid, 0)`은 `0=생존`, `ESRCH=이미 종료`, `EPERM=존재하지만 권한 없음`으로 분기한다. `SIGTERM`/`SIGKILL`의 반환값과 `errno`는 호출 직후 보존한다.
6. 종료 전에는 선택된 대상의 identity 스냅샷을 보여 주고 확인을 받는다. 확인창·종료 중에는 프로세스 목록 자동 갱신을 멈추며, 작업이 끝난 뒤 새로 스캔한다.
7. 시그널 전송과 대기는 메인 액터 밖에서 실행한다. UI는 진행 상태와 프로세스별 outcome을 표시한다.

```swift
import Darwin
import Foundation

enum ProcessTerminator {
    enum Refusal: Equatable {
        case notTerminable, identityChanged, daemonEvidenceChanged, protectedProcess
    }
    enum Outcome: Equatable {
        case terminated, killed, alreadyGone, notPermitted
        case refused(Refusal), failed(Int32)
    }

    /// 재검증이 실패하면 어떤 시그널도 보내지 않는다.
    static func terminate(
        _ process: RunningProcess,
        gracePeriod: TimeInterval = 3
    ) -> Outcome
}
```

`terminate` 내부의 argv 조회는 scan-time `RunningProcess.arguments`를 믿지 않고 2절의 identity A → argv → identity B 절차를 다시 호출한다. argv가 바뀌었거나 exact main class가 없으면 `.refused(.daemonEvidenceChanged)`이며 어떤 시그널도 보내지 않는다. `kill(pid, 0)`은 셸 대신 사용하되 PID 존재 여부만 알려 준다. identity·argv 검증을 대체하지 않는다.

## 7. 원클릭 액션

### 7.1 시뮬레이터 일괄 종료

`SimulatorManager`에 `shutdownAll()`을 추가하고, 기존 `SimulatorViewModel`의 주입·백그라운드 실행·오류 배너 경로로 연결한다. `MemoryTabView`에서 동기적으로 `xcrun`을 호출하지 않는다.

```swift
static func shutdownAll() -> Bool {
    ShellRunner.runXcrun(["simctl", "shutdown", "all"]).succeeded
}
```

기기·앱의 영구 데이터는 지우지 않지만, 실행 중인 앱의 미저장 메모리 상태와 진행 중인 테스트/빌드는 끊긴다. 따라서 "모든 시뮬레이터를 종료합니다. 기기 데이터는 유지되지만 실행 중인 작업은 중단됩니다." 확인 다이얼로그를 띄운다. `SimulatorViewModel`에는 `shutdownAll` 주입점과 성공/실패 테스트를 추가한다.

### 7.2 빌드 데몬 일괄 종료

Gradle·Kotlin 데몬에만 6절 종료 절차를 적용한다. MCP 서버는 에디터/도구가 소유하므로 이 릴리스에서는 표시만 한다. `./gradlew --stop`을 셸로 부르지 않는다 — 프로젝트 디렉터리에 의존하고, DiskTidy는 어느 프로젝트가 그 데몬을 띄웠는지 모른다.

## 8. 파일 구성

```
Sources/DiskTidy/
  Models/MemorySnapshot.swift        신규 — 물리 메모리·스왑 값 객체
  Models/RunningProcess.swift        신규 — ProcessIdentity + ProcessKind + JavaMainClassParser + 단일 TerminationPolicy
  Services/MemoryInfo.swift          신규 — host_statistics64 + vm.swapusage + 스왑 파일 크기 + 오류 상태
  Services/ProcessScanner.swift      신규 — ps PID/RSS 후보 + identity A → KERN_PROCARGS2 → identity B 분류
  Services/ProcessTerminator.swift   신규 — identity/daemon evidence 재검증 + SIGTERM → SIGKILL
  Services/SimulatorManager.swift    수정 — shutdownAll() 추가
  ViewModels/SimulatorViewModel.swift 수정 — shutdownAll 주입·비동기 실행·오류 상태
  ViewModels/MemoryViewModel.swift   신규 — @MainActor, 스캔·종료·timer/task 수명 관리
  Views/SimulatorTabView.swift       수정 — 시뮬레이터 일괄 종료 확인 UI
  Views/MemoryTabView.swift          신규 — 지표 + 스왑 + 프로세스 목록 1탭
  Views/ContentView.swift            수정 — sidebarItems ID 9, detailView 1케이스
```

`CleanableListViewModel`은 재사용하지 않는다. 항목이 `CleanableItem`(경로·크기)이 아니라 프로세스이고, 동작이 삭제가 아니라 시그널 전송이라 모델이 맞지 않는다. 억지로 끼우면 `path`에 가짜 URL을 넣게 된다.

`MemoryViewModel`은 기존 `StorageMonitor`처럼 지표를 기본 5초마다 갱신하고, 프로세스 목록은 20초마다 갱신한다. timer는 하나만 소유해 `deinit`에서 invalidate하고, 진행 중인 스캔 Task는 취소한다. 확인창·종료 중에는 프로세스 목록 갱신을 중단한다. `ps`/Darwin proc API/시그널 대기는 메인 액터 밖에서 수행하고, 취소된 오래된 결과가 최신 상태를 덮지 못하게 세대 토큰 또는 Task identity를 확인한다.

## 9. 테스트 계획

`Tests/DiskTidyTests/MemoryTests.swift` 신규. Swift Testing (`@Suite` / `@Test` / `#expect`).

**`ps` 출력 파싱** — 실제 실행 없이 고정 문자열로:
- 정상 3줄 → pid·rss 정확히 분리
- pid 또는 rss가 아닌 필드·음수·overflow → 파싱 실패
- 빈 줄·헤더 잔여물 → 무시
- `/bin/ps` 실행 실패·비정상 종료·파싱 실패 → 빈 목록이 아니라 `ProcessScanner.Error`, 이전 선택 해제

**identity-bound argv와 분류** — `proc_pidinfo`/`proc_pidpath`/`KERN_PROCARGS2`은 주입 가능한 대역으로 둔다:
- identity A == B + java 실행 파일 + parser가 읽은 Gradle main class → `.devDaemon(.gradle)`
- identity A == B + java 실행 파일 + parser가 읽은 Kotlin main class → `.devDaemon(.kotlin)`
- 다른 main class 뒤 일반 인자로 Gradle/Kotlin 문자열이 있어도 종료 불가 ← **회귀 방지 핵심**
- java가 아닌 실행 파일·알 수 없는 launcher option·main-class 부분 문자열만 일치 → 종료 불가
- argv 읽기 실패·NUL/argc 경계 오류·identity A != B → `.devDaemon`을 만들지 않음
- `ps`가 old PID의 행을 준 뒤 identity A가 다른 일반 프로세스를 가리키는 대역 → old argv와 결합하지 않으며 종료 불가 ← **회귀 방지 핵심**
- node 실행 경로 + 명시적으로 식별 가능한 MCP 엔트리포인트 → `.activeWorkload`, 종료 불가
- `mcp/`만 포함한 일반 argv → `.userApp` 또는 `.activeWorkload`, 종료 불가 ← **회귀 방지 핵심**
- SourceKit·`swift-frontend`·XCBBuildService·Dart/Flutter·Android emulator → `.activeWorkload`, 종료 불가
- 일반 `/Applications` 앱 → `.userApp`, 목록에서 제외

**단일 종료 정책 (`TerminationPolicy.canTerminate`)** — 이 스위트가 이 기능에서 가장 중요하다. `RunningProcess.isTerminable`와 `ProcessTerminator`가 이 함수를 함께 사용한다.

| 입력 | 기대 |
|---|---|
| `/System/Library/...` 경로 | `false` |
| `/usr/libexec/...` 경로 | `false` |
| 이름이 `WindowServer` | `false` |
| pid == 1 | `false` |
| pid == `getpid()` | `false` |
| pid == `getppid()` | `false` |
| 소유자 uid != `getuid()` | `false` |
| 일반 `/Applications/Android Studio.app/...` 프로세스 | `false` |
| `.activeWorkload` 또는 `.userApp` | `false` |
| java가 아닌 실행 파일·알 수 없는 launcher option·다른 main class의 일반 인자에 기대 문자열 포함 | `false` |
| 검증된 Gradle 데몬 identity | `true` |

**스왑 문자열 파서** — `total = 40960.00M  used = 39653.88M  free = 1306.12M  (encrypted)` → 바이트 3값. `M`/`G` 접미사, 소수점 처리 확인.

**종료 절차** — 실제 프로세스를 죽이지 않고 검증하려면 identity 재조회·시그널 전송·생존 probe·대기 시간을 각각 주입 가능하게 둔다.

- SIGTERM에 즉시 죽는 대역 → `.terminated`, SIGKILL 미전송 확인
- 끝까지 안 죽는 대역 → SIGTERM 후 SIGKILL 순서로 전송됐는지 확인 ← **회귀 방지 핵심**
- SIGTERM 뒤 daemon evidence가 바뀐 대역 → SIGKILL 미전송·`.refused(.daemonEvidenceChanged)`
- 처음부터 없는 pid → `.alreadyGone`
- `kill(pid, 0)`이 `EPERM` → `.notPermitted`, `.terminated`로 오인하지 않음
- UID·시작 시각·실행 경로 중 하나라도 스캔 결과와 다름 → `.refused(.identityChanged)`, 시그널 미전송 ← **회귀 방지 핵심**
- 재조회 argv의 exact main-class가 scan-time evidence와 다르거나 읽기 실패 → `.refused(.daemonEvidenceChanged)`, 시그널 미전송
- SIGTERM/SIGKILL 자체가 실패 → 보존한 `errno`를 담은 `.failed`, 성공으로 표시하지 않음

**뷰모델/시뮬레이터** — 확인창·종료 중 자동 프로세스 갱신이 멈추고, 완료 뒤 한 번만 갱신되는지 검증한다. `SimulatorViewModel.shutdownAll`은 성공·실패·확인 후 실행을 주입 대역으로 검증한다.

`MemoryInfo`의 `host_statistics64`/`vm.swapusage` 경로는 시스템 상태에 의존하므로 "값이 0보다 크다" 수준의 스모크 테스트와 "측정 실패가 0으로 표시되지 않음" 테스트를 둔다. macOS 13/Intel 실기에서 `KERN_PROCARGS2` 자기 PID 조회를 포함해 한 번 수동 스모크 테스트한다.

## 10. 위험과 완화

| 위험 | 영향 | 완화 |
|---|---|---|
| PID 재사용으로 다른 프로세스 종료 | 치명적 | `ps` argv 미사용. 종료 직전 identity A → argv → identity B와 exact main-class를 재검증하고, SIGKILL 전에도 다시 확인 |
| 시스템/일반 앱 종료 → 로그아웃·작업 유실 | 치명적 | `TerminationPolicy` 하나로 `.devDaemon` allowlist·UID·PID·경로·이름·실제 Java main class를 함께 차단. 일반 앱·active workload는 종료 버튼 없음 |
| 저장 안 한 작업 유실 | 높음 | 대상 identity 스냅샷 확인 + SIGTERM 우선. 시뮬레이터 종료도 확인 다이얼로그 |
| Gradle 데몬 강제 종료로 락 파일 잔류 | 중간 | 3초 유예 후에만 SIGKILL, 실패 outcome을 숨기지 않음 |
| RSS 근사치를 회수량으로 오해 | 중간 | UI에 "근사치" 명시, 회수량 약속 문구 금지 |
| 메모리/스왑 수집 실패를 0으로 오인 | 중간 | 지표별 측정 불가 상태와 오류 배너 표시 |
| `xsw_usage` Swift 임포트 실패 | 낮음 | 현재 환경 검증 완료. 대상 빌드/실기 실패 시에만 문자열 파서 대체 (3.3절) |
| 스왑을 지우거나 정해진 용량을 회수할 수 있다고 오해 | 중간 | 스왑 섹션은 읽기 전용, 현재 관측값과 재시동 고려 조건만 표시 |
| timer/task 잔류·오래된 결과 덮어쓰기 | 중간 | 단일 timer, `deinit` 취소, 확인/종료 중 갱신 중단, 세대 토큰 확인 |

## 11. 작업 순서

1. `MemoryInfo` — `host_statistics64` + `vm.swapusage` + 스왑 파일 크기 + 측정 실패 계약. macOS 13/Intel 스모크 대상도 정한다
2. `ProcessIdentity`·`KERN_PROCARGS2`/Java main-class 파서·Darwin proc API 조회·단일 `TerminationPolicy` (순수 로직) → **테스트 먼저**
3. `ProcessTerminator` — identity 재검증·errno 분기·시그널 주입 형태로 → 테스트
4. `SimulatorManager.shutdownAll()`을 `SimulatorViewModel`/`SimulatorTabView` 확인 UI와 함께 구현 → 테스트
5. `MemoryViewModel` + `MemoryTabView` — timer/task 수명과 확인 중 갱신 중단을 포함
6. `ContentView` ID 9 등록. 임시파일 탭 ID 8과 충돌하지 않는지 확인
7. 실기 검증: 시스템·일반 앱·active workload에 종료 버튼이 없는지 확인 → Gradle 데몬 종료 → identity가 같은지와 `ps` 소멸 확인 → 재빌드 정상 동작 → 시뮬레이터 종료 시 영구 데이터 유지 확인
8. 기능이 실제 출시된 뒤 README 화면 수·삭제 정책·직접 배포/샌드박스 조건·스왑의 읽기 전용 관측 한계를 갱신

## 12. 참고 — 실측에 쓴 명령

```bash
sysctl vm.swapusage                        # used = 39653.88M
sysctl kern.memorystatus_vm_pressure_level # 2 (warning)
memory_pressure -Q                         # free 28%, page size 16384
ls -lh /System/Volumes/VM                  # swapfile0 ~ swapfile40
df -h /System/Volumes/VM                   # 41Gi used
ls -l /usr/sbin/purge                      # 권한/파일 모드 확인 (실행 여부의 근거로 단독 사용 금지)
ps -axo rss,pid,comm -r | head -25
pgrep -l -f "GradleDaemon|KotlinCompileDaemon|SourceKitService|node"
```
