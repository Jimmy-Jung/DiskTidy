# 임시파일 정리 (tmp Cleanup) 개발 문서

- 작성자: JunyoungJung
- 작성일: 2026-08-07
- 대상 버전: DiskTidy 1.1.0 (현재 `Info.plist` 1.0.1에서 다음 기능 릴리스)
- 상태: 설계 보강 완료, 구현 대기

---

## 1. 배경

맥북을 장시간 켜둔 채 여러 iOS/Android 프로젝트를 병행하면 `/tmp`에 빌드 산물·스크린 캡처·로그·MCP 서버 잔여물이 계속 쌓인다. macOS는 `/tmp`를 부팅 시점과 주기 작업에서만 정리하므로, 재부팅 없이 며칠~몇 주 켜두면 수십 GB가 남는다.

### 실측 (2026-08-07, macOS 26 / Apple Silicon / 24GB RAM)

| 경로 | 크기 | 비고 |
|---|---|---|
| `/private/tmp` | **26 GB** | 최상위 엔트리 688개 |
| `$TMPDIR` = `/var/folders/<x>/<y>/T/` | 1.0 GB | 사용자·세션 전용 |
| `/var/folders/<x>/<y>/C/` | 1.5 GB | Darwin 사용자 캐시 (clang 모듈·XCBuild) |
| `/private/tmp/claude-501` | 434 MB | AI 코딩 도구 스크래치패드 |

`/private/tmp` 최상위에는 다음이 **섞여 있다**. 이게 이 기능의 난이도 전부다.

```
srwx------  jimmy  2f093fe9-a235-...               ← 유닉스 소켓 (사용 중)
srw-------  jimmy  Visual Studio Code-01f9....sock ← 유닉스 소켓 (사용 중)
-rw-r--r--  jimmy  CalNotificationsAvailable       ← 오늘 만들어진 활성 마커
drwxrwxrwx  jimmy  .dotnet                         ← 툴체인 상태 디렉터리
-rw-r--r--  root   (다수)                          ← 타 사용자/데몬 소유
```

## 2. 목표 / 비목표

**목표**
- `/private/tmp`, `$TMPDIR`의 최상위 엔트리를 크기순으로 보여주고 선택 삭제한다.
- 안전성을 검증할 수 없는 파일·타 사용자 파일·소켓은 후보에서 제외한다 (fail-closed).
- 휴지통을 거치지 않아 삭제한 경로는 즉시 사라진다. 단 APFS 스냅샷·열린 파일 때문에 관측 여유 용량이 즉시 같은 만큼 늘어난다고 약속하지 않는다.

**비목표**
- `/var/folders/<x>/<y>/C/` (Darwin 캐시) — v2로 미룬다. Xcode 모듈 캐시라 삭제 시 재빌드 비용이 있고, 기존 "Xcode 캐시" 탭과 성격이 겹친다.
- 하위 디렉터리 단위 세부 선택 — 최상위 엔트리 단위로 충분하다.
- 자동/주기 정리 — 수동 실행만. 백그라운드 삭제는 되돌릴 수 없어 위험하다.
- App Sandbox / Mac App Store 배포 지원 — 현재 기능은 entitlement 없는 직접 배포 앱을 전제로 한다. 샌드박스 배포가 목표가 되면 접근 범위부터 다시 설계한다.

## 3. 안전 규칙 (이 기능의 본체)

엔트리 하나를 삭제 후보로 인정하려면 **5개 전부** 통과해야 한다. 디렉터리는 자신뿐 아니라 하위 트리 전체가 통과해야 한다. 하나라도 판정 불가면 후보에서 뺀다 (fail-closed).

| # | 규칙 | 근거 |
|---|---|---|
| 1 | 소유자 UID == `getuid()` | `/tmp`은 공용 디렉터리다. root·타 데몬 소유 파일이 섞여 있고, 지울 권한도 없다 |
| 2 | 파일 타입이 정규 파일 또는 디렉터리 | 소켓·FIFO·심볼릭 링크 제외. VS Code / Logi 소켓을 지우면 해당 앱이 즉시 깨진다 |
| 3 | `atime`과 `mtime`이 **둘 다** N일 초과 (v1 기본 3일) | mtime만 보면 "한 번 쓰고 계속 읽는" 파일을 날린다 |
| 4 | `lsof` 결과에 열린 경로로 잡히지 않음 | 오래됐지만 mmap/열려 있는 파일을 거른다 |
| 5 | 루트 디렉터리 자체가 아님 | `/private/tmp`을 통째로 지우는 사고 방지 |

### 디렉터리는 하위 트리까지 검증한다

최상위 디렉터리의 `lstat`만 통과했다고 `FileManager.removeItem`으로 재귀 삭제하면 안 된다. 오래된 사용자 소유 디렉터리 안에도 타 UID 파일·소켓·열린 파일이 있을 수 있고, 디렉터리 삭제 권한은 자식 파일의 소유자와 다를 수 있다.

- 후보 디렉터리는 하위 항목을 링크를 따라가지 않고 순회해 규칙 1~4를 모두 적용한다. 하나라도 실패하면 **디렉터리 전체를 후보에서 제외**한다.
- 순회 중 심볼릭 링크·소켓·FIFO·권한 오류·루트 밖으로 해석되는 경로가 나오면 해당 디렉터리는 제외한다.
- 삭제 직전에는 새 `lsof` 스냅샷과 `lstat`로 같은 트리를 다시 검증한다. 스캔 결과의 URL을 곧바로 `removeItem`에 넘기지 않는다.
- `O_NOFOLLOW` + 디렉터리 FD는 상위 경로 교체와 링크 추적을 막지만, `unlinkat(parentFD, name, ...)` 직전 마지막 이름이 바뀌는 경합까지 원자적으로 막지는 못한다. macOS에는 inode를 조건으로 하는 unlink API가 없다.
- 완전 삭제는 4절의 **격리 이동 프로토콜**을 구현·검증한 경우에만 제공한다. 이 프로토콜을 검증하지 못하면 v1은 후보 스캔과 Finder에서 보기만 출시하고, 정규 파일·디렉터리 모두 삭제 버튼을 내지 않는다.

### 규칙 1·2·3은 `lstat` 한 번으로 끝난다

소유자·타입·두 타임스탬프를 각각 다른 API로 읽으면 호출이 4배가 되고 심볼릭 링크에서 결과가 어긋난다. `lstat(2)`는 넷을 한 번에 주고 링크를 따라가지 않는다.

```swift
var st = stat()
guard lstat(url.path, &st) == 0 else { return nil }   // 판정 불가 → 후보 제외

let isOwnedByMe = st.st_uid == getuid()
let type = st.st_mode & S_IFMT
let isEligibleType = type == S_IFREG || type == S_IFDIR
let mtime = FileTimestamp(
    seconds: Int64(st.st_mtimespec.tv_sec),
    nanoseconds: Int64(st.st_mtimespec.tv_nsec)
)
let atime = FileTimestamp(
    seconds: Int64(st.st_atimespec.tv_sec),
    nanoseconds: Int64(st.st_atimespec.tv_nsec)
)
```

`stat(2)`가 아니라 `lstat(2)`여야 한다. `stat`은 링크를 따라가서 링크 대상의 소유자·시각을 돌려주므로, `/tmp`의 심볼릭 링크가 홈 디렉터리를 가리키면 그 대상 기준으로 판정된다.

### 규칙 4: `lsof` 단 한 번

`lsof +D /private/tmp`는 26GB 트리를 전수 순회하므로 못 쓴다. 사용자 프로세스 전체의 열린 경로를 **한 번에** 받아 component-boundary 매칭한다.

```
/usr/sbin/lsof -w -n -F0n -u <uid>
```

- 실측: **1.2초, 약 89,032 필드**. 스캔 1회당 1번만 실행하면 감당된다.
- `-F0n`은 NUL 종료 필드 출력이다. 줄바꿈이 든 파일명도 필드를 깨지 않으므로 줄 단위 파싱을 쓰지 않는다. `p`(pid)·`f`(fd) 필드는 버린다.
- `n` 필드에는 `nTCP 127.0.0.1:...` 같은 비경로도 온다. **NUL로 나눈 필드가 `n/`로 시작할 때만** 취한다.
- `-w`는 경고 억제. `ShellRunner`가 stderr를 `nullDevice`로 버리므로 중복이지만 명시해 둔다.
- 종료 코드가 0이 아니거나 경로 파싱이 불완전하면 빈 집합으로 취급하지 않고 스캔을 실패시킨다. 이때 이전 후보도 삭제할 수 없게 비운 뒤 오류 배너를 보인다.

```swift
/// 모든 경로를 canonical path로 정규화한 열린 경로 집합.
/// lsof 실행/파싱 실패는 throw한다. 빈 Set은 "열린 경로 없음"만 뜻한다.
static func openPaths() throws -> Set<String>
```

`/tmp`, `/private/tmp`, `$TMPDIR`, `lsof` 출력 모두를 같은 canonical path로 정규화한 뒤 판정한다. 단순 `hasPrefix`가 아니라 path component 경계를 써서 `/private/tmp2`가 `/private/tmp` 하위로 오인되지 않게 한다.

판정은 **양방향**이어야 한다.
- 후보가 파일: 열린 경로에 그 경로가 그대로 있는지.
- 후보가 디렉터리: 열린 경로 중 `후보경로 + "/"` 로 시작하는 게 있는지. 디렉터리 안의 파일 하나만 열려 있어도 디렉터리째 삭제하면 안 된다.

**알려진 한계**: 비-root `lsof`는 root·다른 사용자 프로세스의 파일 핸들을 완전하게 보지 못한다. `atime`도 파일시스템의 갱신 정책에 따라 최근 읽기를 증명하지 못한다. 따라서 이 기능은 사용자 공간에서 관찰 가능한 상태만 보수적으로 거르며, 이 한계와 샌드박스 미지원 조건을 README에 명시한다.

## 4. 삭제 방식 — 휴지통으로는 부족하다

`TrashService.trash()`는 `~/.Trash`로 옮긴다. `/private/tmp`은 `~`와 같은 APFS Data 볼륨이라 이동 자체는 즉시 끝난다. 사용자가 휴지통을 비우기 전까지 디스크 블록은 회수되지 않으므로 tmp 탭에는 맞지 않는다.

그래서 tmp 탭은 **완전 삭제를 기본**으로 하고, 되돌릴 수 없으므로 확인 다이얼로그를 반드시 거친다. 성공은 "경로를 삭제했다"는 뜻이며, APFS 스냅샷이나 열린 파일 때문에 `StorageInfo`의 여유 용량 증가가 지연될 수 있다. UI는 삭제 대상의 합계와 새로 읽은 여유 용량을 별도로 보여 주되 회수량을 약속하지 않는다.

구체적인 API와 outcome 계약은 5절의 `PermanentDeleter`를 따른다. production root policy는 `/private/tmp`과 `NSTemporaryDirectory()`에서 검증·canonicalize한 유효 디렉터리만 가진다. `/`, 홈, 상대 경로, 빈 경로, 존재하지 않는 경로는 정책 생성 단계에서 거부하며 호출부가 루트를 전달할 수 없다.

스캔은 `st_dev + st_ino + uid + mode + mtime + atime`을 `TempCandidate.identity`에 보존한다. 삭제기는 parent directory FD를 기준으로 최종 component를 `lstat`/`openat(O_NOFOLLOW)`해 같은 identity인지 확인하고, 새 `lsof` 스냅샷과 하위 트리 검증을 끝낸 뒤 **같은 파일시스템 안의 격리 디렉터리로 `renameatx_np(..., RENAME_EXCL)` 이동**한다. 이동 뒤 identity가 같을 때만 격리 FD 아래에서 삭제한다. `resolvingSymlinksInPath()`는 최종 대상에 적용하지 않는다. `/tmp` 표기 정규화는 root·후보·열린 경로의 비교용으로만 쓴다.

### 격리 이동·복구 프로토콜과 한계

1. 각 production root 안에 mode `0700`의 DiskTidy 전용 격리 디렉터리와 durable journal을 만들고 directory FD를 연다. journal에는 root-relative source parent/name, candidate identity, stage name, 상태를 기록한다. 이동 전 journal의 준비 레코드를 `fsync`하고, 스캐너는 격리 디렉터리를 일반 후보에서 제외한다.
2. candidate의 parent FD와 final component를 다시 검증한 뒤 `renameatx_np(sourceParentFD, name, quarantineFD, randomName, RENAME_EXCL)`으로 **같은 볼륨 안에서** 원자 이동한다. randomName이 이미 있으면 새 이름으로 제한 횟수 재시도하고, 그 외 오류·`EXDEV`에는 복사/삭제 fallback 없이 실패한다. plain `renameat`은 목적지를 덮어쓸 수 있으므로 쓰지 않는다.
3. 격리 위치에서 `fstatat(..., AT_SYMLINK_NOFOLLOW)`한 identity가 candidate와 다르면 어떤 삭제도 하지 않는다. 복원도 `renameatx_np(quarantineFD, stageName, sourceParentFD, name, RENAME_EXCL)`만 사용한다. 원래 이름이 이미 있으면 덮어쓰지 않고 격리 항목을 보존한 채 `.refused(.quarantineRecoveryRequired)`와 복구 경로를 표시한다.
4. 이동이 성공하면 journal을 staged 상태로 durable하게 기록한다. identity가 같을 때만 격리 FD 기준으로 하위 트리를 다시 검증하고 삭제한다. 성공 삭제 뒤에만 journal을 완료 상태로 기록한다.
5. 앱 시작 시 일반 tmp 스캔보다 먼저 journal과 격리 디렉터리를 대조한다. 준비·staged·손상·orphan 항목은 자동 삭제하지 않고 복구 화면에 보인다. 복원 직전에도 stage identity를 journal과 비교하고, 일치할 때만 `RENAME_EXCL`을 사용한다. 충돌·identity 불일치 항목은 Finder에서 열기와 원본/격리 경로만 제공한다.

> **현재 확인**: 현 Xcode/macOS 환경에서 `renameatx_np`와 `RENAME_EXCL`은 `Darwin`에 노출된다. macOS 13/Intel에서 이동·목적지 충돌·복원 충돌 스모크 테스트를 추가한다.

이 절차는 일반적인 동시 경로 교체에서 **다른 항목을 삭제하지 않기 위한** 보호다. 그러나 같은 UID의 적대 프로세스는 격리 디렉터리도 조작할 수 있고, macOS에는 inode 조건부 unlink가 없다. 따라서 이 기능의 위협 모델은 적대적인 동일 UID 프로세스를 포함하지 않는다. 그 모델까지 지원해야 하면 완전 삭제 기능은 출시하지 않는다.

## 5. API 설계

### 신규 `Sources/DiskTidy/Models/TempCandidate.swift`

`CleanableItem`은 화면 표시와 휴지통 이동만 표현한다. 스캔 당시의 파일 동일성을 보존하지 않으므로, 완전 삭제 대상에는 사용하지 않는다.

```swift
import Foundation

struct FileTimestamp: Hashable {
    let seconds: Int64
    let nanoseconds: Int64
}

struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
    let ownerUID: UInt32
    let mode: UInt32
    let modifiedAt: FileTimestamp
    let accessedAt: FileTimestamp
}

struct TempCandidate: Identifiable, Hashable {
    struct ID: Hashable {
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
    }

    let name: String
    let path: URL
    let canonicalPath: String
    let sizeBytes: Int64
    let modifiedDate: Date
    let identity: FileIdentity
    var isSelected = false

    /// 구분 문자를 직렬화하지 않아 `:`가 든 합법 경로도 충돌하지 않는다.
    var id: ID {
        ID(canonicalPath: canonicalPath, device: identity.device, inode: identity.inode)
    }
}
```

`FileIdentity`의 값은 모두 `lstat`에서 채운다. `URL`이나 경로 문자열만으로 삭제 대상을 다시 찾는 방식은 허용하지 않는다.

### 신규 `Sources/DiskTidy/Services/TempRootPolicy.swift`

스캔과 삭제가 서로 다른 루트 판정을 하면 안전 규칙이 무너진다. 두 서비스가 공유하는 내부 정책은 `/private/tmp`과 `NSTemporaryDirectory()`만 canonicalize·중복 제거해 production root로 만든다. `/`, 홈, 상대/빈/존재하지 않는 경로는 정책 생성 단계에서 거부하며, 포함 판정은 component boundary를 사용한다.

UI나 삭제 호출부에는 루트를 받는 API를 제공하지 않는다. 통합 테스트는 실제 `NSTemporaryDirectory()` 아래에 고유한 픽스처를 만들고 정리하므로 production root 정책을 우회하지 않는다.

### 신규 `Sources/DiskTidy/Services/TempScanner.swift`

```swift
import Darwin
import Foundation

enum TempScanner {
    /// v1 고정 보존 기간: 3일.
    static let defaultMinimumAgeDays = 3

    enum ScanError: Error, Equatable {
        case invalidMinimumAge
        case inaccessibleRoot(String)
        case openPathQueryFailed(Int32)
        case malformedOpenPathOutput
    }

    /// lsof 또는 루트 열거 실패는 빈 목록이 아니라 throw다.
    static func scan() throws -> [TempCandidate]

    /// canonical path만 반환한다. exitCode != 0 또는 불완전한 파싱은 ScanError를 던진다.
    static func openPaths() throws -> Set<String>

    // MARK: 순수 판정 로직 (파일시스템 없이 테스트 가능)

    enum Decision: Equatable {
        case eligible
        case notOwned, wrongType, tooRecent, inUse, isRoot, invalidConfiguration
    }

    static func decide(
        stat: stat, path: String, rootPaths: Set<String>,
        openPaths: Set<String>, now: Date, minimumAgeDays: Int
    ) -> Decision
}
```

`decide`를 순수 함수로 분리하는 게 핵심이다. `stat` 구조체를 손으로 만들어 넣으면 소유자·타입·시각 조합 전부를 실제 파일 없이 검증할 수 있다. `minimumAgeDays`는 0 이상만 허용하고, 문서의 "N일 초과"는 정확히 `age > N일`로 정의한다. 미래 시각은 `.tooRecent`으로, canonicalization 실패는 `.invalidConfiguration`으로 처리한다.

### 신규 `Sources/DiskTidy/Services/PermanentDeleter.swift`

```swift
import Foundation

enum PermanentDeleter {
    enum Outcome: Equatable {
        case deleted
        case refused(Refusal)
        case failed(Int32)
    }

    enum Refusal: Equatable {
        case outsideProductionRoot, identityChanged, inUse, unsafeTree
        case quarantineUnavailable, quarantineRecoveryRequired
    }

    enum RestoreOutcome: Equatable {
        case restored
        case refused(Refusal)
        case failed(Int32)
    }

    struct QuarantineRecovery: Identifiable, Hashable {
        let id: UUID                       // durable journal ID
        let originalPath: String
        let quarantinedPath: URL
    }

    /// 되돌릴 수 없다. 반드시 사용자 확인 뒤에만 호출한다.
    static func delete(_ candidate: TempCandidate) -> Outcome
    static func pendingRecoveries() -> [QuarantineRecovery]
    /// journal ID로만 복원한다. 임의 source/destination path는 받지 않는다.
    static func restore(_ recoveryID: UUID) -> RestoreOutcome
}
```

v1의 보존 기간은 고정 3일이며 UI와 삭제 호출부가 루트·시간·`lsof` 결과를 주입할 수 없다. `PermanentDeleter` 내부의 private `QuarantineJournal`은 journal ID에서만 source/stage FD를 다시 열어 복원한다. `TempRootPolicy` 밖의 경로·identity 변경·트리 검증 실패는 모두 `.refused`다. `PermanentDeleter`는 일반 root에서 바로 `unlinkat`하지 않고, 4절의 `RENAME_EXCL` 격리 이동 뒤 identity가 일치할 때만 격리 FD에서 삭제한다. durable journal·격리 이동·identity 재확인·복구 경로를 모두 검증하지 못하면 삭제 기능은 출시하지 않는다.

### 신규 `Sources/DiskTidy/ViewModels/TempCleanupViewModel.swift`

완전 삭제는 `TempCandidate`의 identity를 삭제 시점까지 보존해야 하므로 `CleanableListViewModel`을 일반화하지 않는다. `TempCleanupViewModel`은 `[TempCandidate]`, 스캔/삭제 진행 상태, 오류 배너, 선택 합계와 다음 동작만 가진다.

```swift
@MainActor
final class TempCleanupViewModel: ObservableObject {
    @Published var items: [TempCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isDeleting = false
    @Published var errorMessage: String?
    @Published private(set) var pendingRecoveries: [PermanentDeleter.QuarantineRecovery] = []

    var selectedItems: [TempCandidate]
    var selectedBytes: Int64
    func refresh()
    func deleteSelected()
    func selectAll(_ isSelected: Bool)
    func restore(_ recoveryID: UUID)
}
```

`refresh()`는 먼저 `pendingRecoveries()`를 읽어 복구 섹션을 채운 뒤 `TempScanner.scan()`을 호출한다. 스캔 실패 시 기존 `items`와 선택을 즉시 비우고 오류 배너를 설정한다. `deleteSelected()`는 확인 뒤 스냅샷한 `TempCandidate`만 백그라운드에서 `PermanentDeleter`에 전달하고, outcome별 실패 이유를 보여 준다. `restore(_:)`는 journal ID만 전달한다. 기존 캐시 탭의 `CleanableListViewModel`·`CleanableListView`·`TrashService`는 수정하지 않는다.

### 신규 `Sources/DiskTidy/Views/TempTabView.swift`

기존 목록의 배치만 작게 따르되 `TempCleanupViewModel` 전용으로 구성한다. `TempCandidateList`는 이 파일 안의 private 보조 View로 둔다. `CleanableListView`를 범용화하면 identity 없는 `CleanableItem`까지 완전 삭제 계약에 섞이므로 재사용하지 않는다.

```swift
struct TempTabView: View {
    @StateObject private var viewModel = TempCleanupViewModel()
    @State private var showDeleteConfirmation = false

    var body: some View {
        TempCandidateList(viewModel: viewModel)
        // "완전 삭제"는 이 상태만 열고, confirmationDialog의 확인 액션에서만
        // viewModel.deleteSelected()를 호출한다.
        .onAppear { if viewModel.items.isEmpty { viewModel.refresh() } }
    }
}
```

삭제 버튼은 스캔·삭제 중과 선택 항목이 없을 때 비활성화한다. 확인 문구는 “선택한 항목을 완전히 삭제합니다. 휴지통을 거치지 않으며 되돌릴 수 없습니다.”로 고정한다. 복구 섹션은 일반 후보와 분리해 원본/격리 경로, `Finder에서 열기`, `복원`만 제공하고 자동 삭제하지 않는다. 삭제 성공 후에는 실제 경로 삭제와 새 `StorageInfo` 여유 용량을 별도 표시한다.

### 수정 `Sources/DiskTidy/Views/ContentView.swift`

`sidebarItems`에 한 줄, `detailView(for:)`에 한 케이스 추가.

```swift
SidebarItem(id: 8, title: "임시파일", systemImage: "clock.badge.xmark"),
```

개발 데몬 정리 탭은 다음 ID인 `9`를 사용한다. 두 기능을 병렬 구현해도 ID가 충돌하지 않는다.

## 6. 성능

`DiskScanner.sizes(of:)`가 `du -sk`를 200개씩 묶어 호출한다. 688개 엔트리 / 26GB 트리라 **수십 초** 걸린다. 디렉터리 하위 트리 검증과 삭제 직전 재검증도 같은 규모로 오래 걸릴 수 있다. 모든 파일시스템/lsof 작업은 `Task.detached(priority: .userInitiated)`에서 수행하고, 스캔 중에는 삭제를 막는다.

v1에서는 진행률 없이 기존 `ProgressView` 스피너만 쓴다. 사용자가 몇 분씩 기다린다는 불만이 나오면 그때 엔트리 단위 진행률을 붙인다.

## 7. 테스트 계획

`Tests/DiskTidyTests/TempScannerTests.swift` 신규. Swift Testing (`@Suite` / `@Test` / `#expect`)으로 작성하고, 통합 테스트는 `NSTemporaryDirectory()` 아래의 고유 이름 픽스처만 사용한다.

**순수 판정 (`decide`)** — `stat` 구조체를 직접 구성해 주입:

| 케이스 | 기대 |
|---|---|
| 타 UID 소유 | `.notOwned` |
| 소켓 (`S_IFSOCK`) | `.wrongType` |
| 심볼릭 링크 (`S_IFLNK`) | `.wrongType` |
| mtime 10일 전 · atime 1시간 전 | `.tooRecent` ← **회귀 방지 핵심** |
| mtime·atime 모두 10일 전 | `.eligible` |
| `openPaths`에 정확히 포함 | `.inUse` |
| 후보 디렉터리 **하위** 파일이 `openPaths`에 있음 | `.inUse` ← **회귀 방지 핵심** |
| 경로가 루트 자체 | `.isRoot` |
| `minimumAgeDays < 0` | `.invalidConfiguration` |
| 정확히 N일 경과 | `.tooRecent` (`N일 초과`만 허용) |
| 미래 `mtime` 또는 `atime` | `.tooRecent` |

**lsof 파싱** — 실제 실행 없이 NUL 종료 고정 문자열로:
```
p1234\0fcwd\0n/private/tmp/foo\0f3\0nTCP 127.0.0.1:8080\0
```
→ `{"/private/tmp/foo"}`만 나와야 한다. `nTCP …`와 줄바꿈이 든 경로가 섞여도 필드 경계가 깨지지 않아야 한다.

**스캔 실패** — `lsof` 비정상 종료·경로 파싱 실패·루트 열거 실패는 `[]`이 아니라 `ScanError`가 되어야 한다. 화면은 이전 후보를 비우고 오류 배너를 보여야 한다.

**디렉터리 트리** — 사용자 소유 최상위 디렉터리 안에 타 UID 파일·소켓·심볼릭 링크·열린 파일을 각각 넣어, 어느 하나라도 있으면 부모 디렉터리가 후보에서 제외되는지 검증한다.

**PermanentDeleter 경계** — 실제 `NSTemporaryDirectory()` 아래의 고유 픽스처로 삭제:
- production root 안의 파일 → `.deleted`, 실제로 사라짐
- production root **밖**의 파일 → `.refused(.outsideProductionRoot)`, 파일 그대로 존재 ← **회귀 방지 핵심**
- `/tmp` 표기와 `/private/tmp` 표기를 섞어 넣어도 같은 판정
- 스캔 뒤 대상의 UID·inode·mtime·atime·열린 상태를 바꾼 대역 → `.refused`, 삭제 거부 ← **회귀 방지 핵심**
- 안전하지 않은 하위 항목이 하나라도 있는 디렉터리 → `.refused(.unsafeTree)`, 삭제 미시도
- 검증 뒤 final component가 바뀐 대역 → 격리 위치 identity 불일치, 새 항목 미삭제·원래 이름이 비어 있으면 `RENAME_EXCL` 복원 후 `.refused(.identityChanged)` ← **회귀 방지 핵심**
- stage destination이 이미 있는 대역 → `RENAME_EXCL`이 `EEXIST`, 기존 격리 항목 미변경·새 stage name 재시도
- 복원 전 원래 이름이 다시 채워진 대역 → `RENAME_EXCL` 덮어쓰기 없이 격리 항목 보존·`.refused(.quarantineRecoveryRequired)`와 복구 경로 표시
- journal ID의 복원 대상 원래 이름이 비어 있음 → `.restored`, stage 항목과 journal 완료 상태가 함께 사라짐
- 복원 전 stage identity가 journal과 달라진 대역 → 복원·삭제 미시도, Finder 복구 경로만 표시
- 앱 종료를 모사한 준비/staged journal·손상 journal·orphan stage → 다음 시작 시 복구 목록에만 표시, 자동 삭제 금지
- `:`를 포함한 두 canonical path → 서로 다른 `TempCandidate.ID`

**스캔 통합** — 고유 픽스처를 `NSTemporaryDirectory()` 아래에 만들어 fixed production root에서 규칙 5개와 하위 트리 검증이 함께 걸리는지 확인.

## 8. 위험과 완화

| 위험 | 영향 | 완화 |
|---|---|---|
| 사용 중 파일 삭제 → 앱/빌드 깨짐 | 높음 | 하위 트리까지 규칙 1~4 적용 + 삭제 직전 재검증 + identity 확인 `RENAME_EXCL` 격리 이동. 격리 프로토콜이 없으면 삭제 기능 미출시 |
| 완전 삭제라 복구 불가 | 높음 | 확인 다이얼로그 + canonical root 경계 + 재검증 실패 시 거부 |
| 마지막 이름 교체로 다른 항목 삭제 | 높음 | 일반 root에서 직접 unlink 금지. 이동·복원 모두 `RENAME_EXCL`; identity 일치 시에만 삭제; 동일 UID 적대 프로세스는 지원 위협 모델 밖 |
| 앱 종료 뒤 격리 항목 고립 | 높음 | durable journal + 시작 시 복구 목록. 손상/orphan도 자동 삭제하지 않고 Finder 복구 경로 제공 |
| `lsof` 실패를 빈 결과로 오인 | 높음 | `openPaths()` throw, 목록 비움, 오류 배너. 삭제 버튼 비활성화 |
| `lsof`가 root 데몬의 파일 핸들을 못 봄 | 중간 | 관찰 한계를 README에 명시. `atime`을 사용 중 증명으로 취급하지 않음 |
| 26GB `du` 스캔이 오래 걸림 | 낮음 | 이미 백그라운드. 스피너 표시 |
| `/tmp` ↔ `/private/tmp` 표기 불일치로 경계 검사 우회 | 높음 | 루트·후보·열린 경로를 모두 canonicalize하고 component-boundary 비교 |
| 삭제했지만 여유 용량이 바로 늘지 않음 | 중간 | 삭제 성공과 관측 여유 용량을 분리해 표시. APFS 스냅샷/열린 파일 가능성을 안내 |

## 9. 작업 순서

1. canonical path·`TempScanner.decide`·lsof 파서·오류 계약 (순수 로직) → **테스트 먼저**
2. `TempScanner.scan`의 루트/하위 트리 검증과 스캔 실패 경로 → 테스트
3. `PermanentDeleter`의 삭제 직전 재검증·`RENAME_EXCL` 격리/복원·durable journal 시작 복구 → 테스트. 하나라도 검증하지 못하면 완전 삭제를 기능 범위에서 제외
4. `TempCandidate`와 `TempCleanupViewModel`의 identity 보존·오류/outcome 표시 → 테스트
5. 확인 상태를 포함한 `TempTabView` + `ContentView` ID 8 등록. 기존 8개 탭 회귀 확인
6. 실기 검증: `/private/tmp` 스캔 → 소켓·타 UID·트리 내부 열린 파일이 후보에 없는지 확인 → 선택 삭제 → 경로 삭제와 `StorageInfo` 여유 용량 변화를 분리 확인
7. 기능이 실제 출시된 뒤 README 스크린샷·화면 수·완전 삭제 정책·관찰 한계를 갱신

## 10. 참고 — 실측에 쓴 명령

```bash
du -sh /private/tmp                         # 26G
du -sh "$TMPDIR"                            # 1.0G
getconf DARWIN_USER_TEMP_DIR                # /var/folders/<x>/<y>/T/
getconf DARWIN_USER_CACHE_DIR               # /var/folders/<x>/<y>/C/
ls -la /private/tmp | head -20              # 소켓·타 UID 파일 확인
time /usr/sbin/lsof -w -n -F0n -u "$(id -u)" >/dev/null  # NUL 필드 출력 / 1.2초
```
