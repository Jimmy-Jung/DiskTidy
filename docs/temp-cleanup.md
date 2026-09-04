# 임시파일 정리 (tmp Cleanup) 개발 문서

- 작성자: JunyoungJung
- 작성일: 2026-08-07
- 대상 버전: DiskTidy 1.1.0 (현재 `Info.plist` 1.0.1에서 다음 기능 릴리스)
- 상태: **구현 완료** (2026-08-10). 5절 API·격리 이동 프로토콜·복구 목록까지 전부 구현하고 실기 검증했다.

> **구현 후 메모 (2026-08-10)**
>
> - `renameatx_np` / `RENAME_EXCL`은 현 Xcode(macOS 26 SDK)에서 Swift에 그대로 노출된다. `EEXIST`로 목적지 덮어쓰기를 막는 것까지 테스트로 고정했다.
> - 실기 검증: `/private/tmp` 최상위 30개(실제 소켓 10개·타 UID 6개 포함)에서 합성 픽스처로 규칙 5개를 확인했다. 열린 파일을 품은 디렉터리·FIFO를 품은 디렉터리·최근 파일·유닉스 소켓 모두 후보에서 빠졌고, 안전한 디렉터리만 삭제됐다(여유 용량 +2,002,944 B = 픽스처 2MB). sticky bit 디렉터리 밖으로의 격리 이동도 실기에서 동작한다.
> - `delete()`는 후보 경로에 `/tmp`→`/private/tmp` **표기 정규화**를 적용한다. 정규화하지 않으면 루트 밖으로 오판할 뿐 아니라, 부모가 심볼릭 링크라 `O_NOFOLLOW` 열기가 `ELOOP`로 실패한다. 최종 대상에 `resolvingSymlinksInPath()`를 거는 것과는 다르다.
> - 격리 디렉터리 준비는 `lstat`→`mkdir` 사이 경합을 견딘다. `EEXIST`를 성공으로 보되 소유자·0700 확인은 그대로 남긴다.
> - **4절 2~3단계의 경합 구간도 테스트로 고정했다.** 실제 경합은 재현할 수 없으므로, 이동이 끝난 직후·identity 재확인 **직전**에 훅을 걸어 결정적으로 만들었다(`PermanentDeleter.StageHooks` — 기본값이 곧 production 동작이고 `delete(_:)` 표면은 그대로다). 고정한 경로 4개: ① 격리 항목이 다른 파일로 바뀜 → 새 항목을 지우지 않고 되돌림 ② 되돌릴 원래 이름이 이미 채워짐 → 덮어쓰지 않고 격리 보존 ③ 격리 항목이 사라짐 → 복구 목록에 노출 후 걷힘 ④ stage 이름 충돌 → 기존 격리 항목 무변경 + 새 이름 재시도 + 버려진 준비 레코드 정리.
>   - **변이 검사로 비어 있지 않음을 확인했다.** 이동 후 identity 검사를 `guard true`로 무력화하니 갈아치운 파일이 실제로 삭제됐고(`.deleted`, 원본 경로 소멸), `renameatx_np(RENAME_EXCL)`을 plain `renameat`으로 바꾸니 복구 대기 중이던 기존 격리 항목이 덮어써졌다. 두 테스트 모두 그 자리에서 실패한다.
>
> **변이 검사 (2026-08-10)** — 안전 가드를 하나씩 무력화하고 전체 테스트를 돌려, 어느 테스트도 잡지 못하는 가드를 찾았다. **최종 30개 중 28개가 잡힌다.** 처음 놓친 것들의 원인은 셋으로 갈렸다.
>
> - **테스트가 진짜 가짜였던 것 5개** — 보강해 전부 잡히게 했다.
>   - `scan()`의 `st_dev` 대조: 처음엔 내용이 든 볼륨을 붙여 검증했는데, 그러면 하위 트리 검증이 device 불일치로 **먼저** 잡아 스캔 단계 가드가 중복이 된다. **빈 볼륨**을 붙여야 이 가드만 남는다.
>   - `delete()`의 부모 device 대조: 같은 마운트 테스트에서 후보를 손으로 만들어 넘기면 `.refused(.unsafeTree)`다.
>   - `TempRootPolicy.validated`의 `/`·홈 거부: 현 후보 목록(`/private/tmp`, `$TMPDIR`)으로는 도달하지 않는 방어라, 함수를 internal로 열어 직접 검증한다.
>   - journal의 `..` 차단: 기존 테스트가 `../../../../Users/somebody`를 썼는데 그 경로가 **존재하지 않아** 가드가 없어도 `open`이 실패해 같은 결과가 나왔다. 존재하고 쓸 수 있는 상위 경로(`..`)로 바꾸니 가드 없이는 파일이 루트 밖으로 나간다.
>   - `TempCandidate.ID` 충돌: 서로 다른 두 파일로 비교하면 inode가 달라 무조건 통과했다. identity를 똑같이 두고 경로만 달리해야 실제 계약을 검증한다.
> - **내 근거가 틀렸던 것 1개** — `DiskScanner`의 `du` 인자. `--`를 넣으며 "`-`로 시작하는 이름이 옵션으로 먹힌다"고 했지만, 호출부는 **항상 절대 경로**를 넘기므로 도달할 수 없는 상황이었다. 함께 넣었던 `-x`도 어떤 테스트로도 검증되지 않고 기존 6개 탭의 동작을 근거 없이 바꾸므로, `DiskScanner`는 원래대로 되돌렸다.
> - **원리상 테스트할 수 없는 것 2개** — 방어는 유지하고 `isUsableDirectory` 주석에 이유를 적었다.
>   - 격리 디렉터리 `st_uid == getuid()`: 타 UID 소유 디렉터리를 만들려면 root 권한이 필요하다.
>   - `fchmodat(AT_SYMLINK_NOFOLLOW)`: 링크가 미리 있으면 `lstat`이 성공해 `S_IFLNK`로 걸러지므로 chmod 분기에 도달하지 않는다. `chmod`와의 차이는 `lstat` 실패 직후 링크가 끼어드는 경합에서만 드러난다.
>
> 검사 중 타이밍 의존 테스트도 하나 드러났다. 복구 목록이 스캔보다 먼저 뜨는지 확인하는 테스트가 0.2초 지연에 기대고 있어 부하 상태에서 8회 중 1~3회 실패했다. 세마포어로 스캔을 붙잡는 방식으로 바꿔 8회 연속 통과를 확인했다.
> - **`identity`에 든 `atime`과 우리 자신의 읽기**: 스캔의 `du -sk`와 삭제 직전 하위 트리 재검증이 디렉터리를 읽는다. APFS 실측 결과, 방금 만든 디렉터리(inode가 이미 dirty)는 `du` 후 atime이 갱신되지만 10일 전 타임스탬프를 가진 디렉터리는 `du`·`ls` 후에도 갱신되지 않는다. 후보는 규칙 3 때문에 **항상 atime이 3일 초과인 cold inode**뿐이라 이 경합은 구조적으로 자기 제한된다. 그래도 갱신이 일어나면 결과는 `.refused(.identityChanged)` 거부이지 삭제 사고가 아니며, 다시 스캔하면 해소된다. 그래서 identity에서 atime을 빼지 않았다.
>   - 이 때문에 `scan()`은 규칙 판정과 identity 캡처를 **모두 끝낸 뒤에** `du`를 부른다. 순서가 뒤집히면 자기 `du`가 갱신한 atime을 보고 모든 디렉터리가 `.tooRecent`로 빠진다.
> **리뷰 후 보강 (2026-08-10)** — 6개 관점 병렬 리뷰 + 적대적 검증에서 확정된 결함을 전부 반영했다. 실측으로 재확인한 것만 적는다.
>
> - **극단 타임스탬프로 앱이 죽는 경로를 막았다.** `utimes(path, -9223372037)`이 성공하고 APFS가 그 값을 그대로 저장한다. `seconds * 1_000_000_000`이 Int64를 넘어 Swift가 트랩하므로, `/private/tmp`(1777)에 그런 파일 하나만 있으면 탭을 여는 것만으로 프로세스가 죽고 앱 안에서 빠져나갈 수 없었다. 표현 범위 밖은 판정 불가로 보고 후보에서 뺀다. `minimumAgeDays`에도 상한(100,000일)을 뒀다.
> - **마운트 경계를 넘지 않는다.** 최상위 엔트리가 마운트 포인트면 `renameatx_np`가 `EXDEV`로 막히지만, 마운트를 **품은** 디렉터리는 `rc=0`으로 이동에 성공한다(실측). 그 상태로 재귀 삭제하면 남의 볼륨 내용을 지운다. 후보·하위 항목·삭제 직전 재검증 전부 루트 `st_dev`와 대조하고, `du`에도 `-x`를 붙였다. 실기 재확인: 8MB 볼륨을 `/private/tmp/<dir>/mnt`에 붙여도 `<dir>`이 후보에 오르지 않는다.
> - **쓰기 권한 없는 디렉터리를 후보에서 뺐다.** `0555` 디렉터리가 섞인 트리에서 `removeItem`은 형제 파일 일부를 지운 뒤 멈춘다(실측: 6개 중 3개 삭제 후 실패). 그 시점에 mtime이 바뀌어 복원까지 막혔다.
> - **경로 경계 비교를 UTF-8 바이트로 바꿨다.** `String.hasPrefix`는 grapheme cluster 단위라 `/private/tmp/` + U+0301에서 구분자가 다음 글자와 묶여 진짜 하위 경로가 "하위 아님"이 됐다(실측). 규칙 4가 그 경로에서 죽는 문제였다.
> - **journal 레코드를 임시 파일 + `rename`으로 갈아 끼운다.** 살아 있는 레코드를 `O_TRUNC`로 자르면 그 틈에 전원이 나갔을 때 0바이트 레코드가 남아 원본 경로를 잃는다. 매체 커밋은 `F_FULLFSYNC`로 한다.
> - **이동 후 트리 재검증의 `lsof` 스냅샷을 다시 찍는다.** 이동 전 스냅샷은 격리 경로와 접두사가 영영 일치하지 않아 마지막 관문에서 규칙 4가 통째로 죽어 있었다.
> - **stage도 원본도 없는 `staged` 레코드를 걷는다.** 삭제 성공과 journal 정리 사이에 앱이 죽으면, 복원도 삭제도 안 되는 행이 영구히 남았다.
> - **`mkdir` 경합에서 `chmod`가 심볼릭 링크를 따라가던 것**을 `fchmodat(..., AT_SYMLINK_NOFOLLOW)`로 바꿨다. `/private/tmp`은 1777이라 타 UID가 그 틈에 링크를 끼울 수 있다(실측: `mkdir errno=17` 뒤 대상 모드 644→700).
> - **이미 사라진 대상은 `.deleted`로 본다.** `/tmp`은 macOS 주기 작업이 상시 정리한다. `.failed(ENOENT)`로 두면 목록에 남아 누를 때마다 "errno 2"가 반복됐다.
> - **`ShellRunner`가 비UTF8 바이트에 출력 전체를 버리던 것**을 치환 디코딩으로 바꿨다. 파일명 하나 때문에 `lsof` 결과가 통째로 사라져 탭이 영구 정지했다.
> - **ViewModel에 주입 seam을 뒀다**(기존 `CleanableListViewModel`과 같은 방식). 스캔 실패 시 목록 비움, 삭제 중 선택 변경, 격리 잔류 항목 이동, 복원이 스캔 배너를 지우지 않는 것까지 실제 파일시스템 없이 고정했다.
>
> - 이 문서 6절의 실측치(26GB / 688 엔트리)는 2026-08-07 기준이다. 2026-08-10 재부팅 후 같은 머신은 `/private/tmp` 364KB / 22 엔트리, 스캔 0.25초였다.

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
| 3 | 출처별 시간 규칙 (3-A절). 출처 모름: `atime`과 `mtime`이 **둘 다** N일 초과 (기본 1일). 에이전트 작업물: 세션·빌드 종료 + `mtime` 30분 초과 | mtime만 보면 "한 번 쓰고 계속 읽는" 파일을 날린다. 에이전트 작업물은 읽는 주체가 프로세스라 세션·열린 파일 검사로 대신한다 |
| 4 | `lsof` 결과에 열린 경로로 잡히지 않음 | 오래됐지만 mmap/열려 있는 파일을 거른다 |
| 5 | 루트 디렉터리 자체가 아님 | `/private/tmp`을 통째로 지우는 사고 방지 |

추가로 세 가지를 더 막는다. 전부 구현 후 리뷰에서 실측으로 확인한 구멍이다.

| 규칙 | 근거 |
|---|---|
| 후보와 하위 항목의 `st_dev`가 루트와 같아야 한다 | 마운트 포인트를 **품은** 디렉터리는 `renameatx_np`가 성공한다(실측). 그대로 두면 격리로 옮겨진 뒤 재귀 삭제가 마운트된 볼륨 내용까지 지운다. 최상위가 마운트 포인트인 경우만은 `EXDEV`로 막힌다 |
| 디렉터리는 소유자 쓰기 권한(`S_IWUSR`)이 있어야 한다 | `0555` 디렉터리는 열거만 되고 자식 unlink는 `EACCES`다. `removeItem`은 원자적이지 않아 형제 파일 일부를 지운 뒤 멈추고, 그 시점에 mtime이 바뀌어 identity 대조가 복원까지 막는다 |
| 하위 트리 깊이는 64를 넘지 않아야 한다 | 넘으면 판정 불가로 보고 후보에서 제외한다 (`TempScanner.maximumTreeDepth`) |

## 3-A. 출처별 판정 — 에이전트 작업물 (2026-09-03 추가)

- 작성자: JunyoungJung · 결정일: 2026-09-03

### 왜 추가했나

여러 프로젝트에서 Claude Code·Codex가 tmp에 소스·빌드 산출물을 계속 쓴다. 실측(2026-09-03 11:40):

| 경로 | 크기 | 정체 | 3일 규칙 판정 |
|---|---|---|---|
| `/private/tmp/codex-dd-agent-plan-arguments-red-fresh` | 806MB | Codex가 `xcodebuild -derivedDataPath`로 만든 DerivedData | 오늘 생성 → 제외 |
| `/private/tmp/codex-dd-agenttrace-category` | 688MB | 같음 | 제외 |
| `/private/tmp/claude-501/…/27ac3ee3…/scratchpad` | 602MB | **끝난** Claude 세션의 스크래치 | 제외 |
| `$TMPDIR/.com.openai.codex.*` 233개 | 24.5MB | Codex app-server 임시 리소스 | 제외 |

전부 오늘 생성이라 후보 0건. 그런데 이것들은 오래됐는지가 아니라 **지금 쓰는 주체가 있는지**로 판정할 수 있다.

### 후보 단위

- Claude: `/private/tmp/claude-<uid>/<프로젝트 슬러그>/<세션 UUID>/` 디렉터리 하나가 후보 단위. `claude-<uid>`나 슬러그 디렉터리는 절대 후보가 아니다 — 통째로 잡으면 살아 있는 세션의 작업 파일까지 날린다. UUID 형태가 아닌 이름은 무시한다.
- DerivedData: `/private/tmp/codex-dd-*` 최상위 디렉터리, 그리고 이름과 무관하게 루트에 `info.plist`와 `Build/`가 둘 다 있는 최상위 디렉터리(에이전트가 `mktemp -d /tmp/<프로젝트>-derived.XXXXXX`로 만든 것. 실측 4개 670MB). Codex는 Claude처럼 세션별 스크래치 디렉터리를 tmp에 두지 않는다 — 세션 데이터는 `~/.codex/sessions`(범위 밖)이고, tmp에는 DerivedData·잡파일·에이전트가 임의 이름으로 쓴 로그만 남는다. 임의 이름 로그는 잡을 방법이 없어 "출처 모름" 규칙을 탄다.
- 잡파일: `$TMPDIR/.com.openai.codex.*`, `codex-*.log`, `_*codex-dd-*.lock`, `claude-context-bucket-<세션>`, `claude-tool-count-<세션>` 파일.
- 그 밖: 기존과 같이 최상위 단위.

### 판정 (기존 규칙 1·2·4·5와 하위 트리 검증·`st_dev`·쓰기 권한·깊이 규칙은 그대로, 규칙 3만 갈린다)

| 클래스 | 삭제 조건 (전부) | 근거 |
|---|---|---|
| Claude 세션 스크래치 | ① 세션 UUID가 **라이브 세션 집합에 없음** ② 열린 파일·cwd 없음 ③ 트리 전체 `mtime` 30분 초과 | 세션이 끝나면 스크래치는 다시 쓰이지 않는다. 재개하면 새로 만든다 |
| Codex 빌드 산출물 | ① 사용자 프로세스 명령줄에 경로 없음(`/tmp`·`/private/tmp` 두 표기) ② 열린 파일·cwd 없음 ③ `mtime` 30분 초과 | 재빌드로 복구된다. 30분은 빌드 사이에 파일이 잠깐 안 열려 있는 순간을 넘기는 여유 |
| 에이전트 잡파일 | 파일이 안 열려 있고 `mtime` 30분 초과. Claude 세션에 딸린 것은 그 세션이 끝났을 때만 | 단독으로 의미 없는 부속물 |
| 출처 모름 | 기존 규칙, 보존 기간 3일 → **1일** | tmp의 큰 몫은 이제 에이전트 클래스가 가져가므로 하루면 충분 |

이 표는 일반 자동 후보 조건이다. 출처가 확인된 Claude 세션·DerivedData가 사용 중이면 규칙 3·4의 예외인 경고 행으로만 표시하고, 사용자가 별도 위험 확인을 해야 강제 삭제 경로를 연다.

**라이브 세션 판정 (세 신호 중 하나면 사용 중)**

1. `~/.claude/sessions/<pid>.json`(`pid`, `sessionId`, `cwd`, `startedAt`) 중 `kill(pid, 0)`이 성공하는 것의 `sessionId`와 같다.
2. 트랜스크립트(`~/.claude/projects/<슬러그>/<세션>.jsonl`)가 정지 기간(30분) 안에 갱신됐다.
3. 같은 프로젝트(슬러그 ≈ cwd, 영숫자만 남겨 비교)에서 **그 트랜스크립트가 마지막으로 쓰이기 전에 시작한** Claude 프로세스가 살아 있다.

1만으로는 부족하다. **json의 `sessionId`는 프로세스가 처음 만든 세션이고 `/resume` 뒤에도 갱신되지 않는다** — 실측(2026-09-03 12:03): pid 89943의 json은 15856e44인데 실제로는 27ac3ee3의 트랜스크립트를 12:03에 쓰고 있었고, AgentChatKit에서도 어느 json에도 없는 세션 47559799가 11:36에 쓰였다. 2·3이 그 구멍을 막는다. 세션이 끝난 뒤 시작한 프로세스는 3에 걸리지 않으므로, 프로젝트 창이 열려 있어도 옛 세션은 후보가 된다. 재개만 하고 아직 한 마디도 안 한 세션은 잡지 못한다 — 그때 남는 것은 재개 시점에 hook이 다시 만든 빈 스크래치이고, 정지 기간 30분이 그 직후를 덮는다.

트랜스크립트 유무 자체는 판정에 쓰지 않는다 — 살아 있는데 트랜스크립트가 없는 세션(첫 메시지 전)이 실측 3개 있었다(1이 잡는다).

**에이전트 트리 안의 심볼릭 링크는 링크만 지운다.** 실측: 602MB 세션 스크래치에 복사한 소스 트리의 상대 링크(`Resources -> ../VideoPlayerKollus/Resources`) 10개가 있어 규칙 2로 영영 후보가 되지 않았다. `.quiet` 규칙의 트리에서는 소유자가 나인 링크를 건너뛰고(따라가지 않으므로 대상은 검사 대상이 아니다) `removeItem`이 링크를 따라가지 않는 것을 테스트로 고정했다. 최상위 후보 자체가 링크인 것과 출처 모름 트리의 링크는 여전히 거른다.

**atime을 보지 않는 이유**: 규칙 3이 atime을 본 것은 "한 번 쓰고 계속 읽는" 파일 때문인데, 에이전트 작업물을 읽는 주체는 그 프로세스이고 그건 ①②가 잡는다. atime을 남기면 우리 `du`가 방금 만든 파일의 atime을 건드려 영영 후보가 되지 않는다(4절 실측).

**살아 있는 세션·참조 중인 DerivedData도 목록에 사용 중 경고 행으로 보이며 선택할 수 있다.** 사유(`사용 중 — Claude 세션 실행 중 (PID n)`)를 주황색으로 표시하고, 하나라도 선택하면 확인 대화상자가 세션·빌드 실패 가능성을 명시하며 버튼을 `강제 삭제`로 바꾼다.

**삭제 직전 재검증은 선택 당시의 경고 상태를 구분한다.** 일반 후보가 스캔과 삭제 사이에 `--resume`으로 살아났거나 빌드가 다시 돌면 계속 `.refused(.inUse)`다. 반면 스캔에서 이미 `isInUse`였고 사용자가 확인한 항목은 시간·라이브 상태, 열린 일반 파일과 활동으로 달라질 수 있는 `mtime`·`atime`만 건너뛴다. 디렉터리를 격리한 뒤에는 `lsof`를 다시 실행해 열린 디렉터리 FD나 cwd가 하나라도 있으면 원위치로 복원하고 `.refused(.inUse)`로 거부한다. production root, 격리 경계, `device`·`inode`·UID·mode, 하위 트리의 소유권·종류·마운트·깊이, `RENAME_EXCL` 격리와 복구 검증은 그대로다. 기본 `delete(_:)`는 여전히 사용 중 행을 거부하고 UI가 확인 후 `delete(_:allowInUse: true)`를 명시적으로 호출한다.

**비목표(이번 결정)**: `~/.codex/sessions`(12.6GB) · `~/.claude/projects`(2GB) 등 tmp 밖 에이전트 데이터. 임시파일 탭 범위가 아니다.

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
4. 이동이 성공하면 journal을 staged 상태로 durable하게 기록한다. identity가 같을 때만 하위 트리를 다시 검증하고 삭제한다. 성공 삭제 뒤에만 journal을 완료 상태로 기록한다.
   - 격리 FD는 identity 확인(`fstatat`)과 `renameatx_np`에만 쓴다. 실제 재귀 삭제는 격리 경로 문자열을 다시 해석한다 — FD 기준 재귀 unlink는 얻는 것 대비 코드가 너무 크고, 격리 디렉터리가 `0700`·우리 소유이며 stage 이름이 갓 만든 UUID라 노출 면이 없다.
   - 재검증에 쓰는 `lsof` 스냅샷은 **격리 경로 기준으로 다시 찍는다**. 이동 전 스냅샷은 `<root>/<name>/…` 형태라 `<root>/.DiskTidyQuarantine/<uuid>/…`와 접두사가 영영 일치하지 않아 규칙 4가 통째로 죽는다.
   - journal 레코드는 임시 파일에 쓰고 `rename`으로 갈아 끼운다. 살아 있는 레코드를 `O_TRUNC`로 제자리에서 자르면 전원 손실이 그 틈에 끼었을 때 0바이트 레코드가 남아 원본 경로를 잃는다. 매체 커밋은 `fsync(2)`가 아니라 `F_FULLFSYNC`로 보장한다.
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
    /// `minimumAgeDays`는 internal 기본값 파라미터다. 상한(100,000일)을 넘거나 음수면
    /// `.invalidMinimumAge`. UI는 이 값을 넘기지 않고, 삭제 경로는 무엇을 넘겼든
    /// 항상 고정 3일로 다시 검증한다.
    static func scan(minimumAgeDays: Int = defaultMinimumAgeDays) throws -> [TempCandidate]

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
    /// 사용 중 경고 행을 확인한 경우에만 활동 검사를 건너뛴다.
    static func delete(_ candidate: TempCandidate, allowInUse: Bool) -> Outcome
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

삭제 버튼은 스캔·삭제 중과 선택 항목이 없을 때 비활성화한다. 사용 중 항목이 없으면 휴지통을 거치지 않는 완전 삭제를, 하나라도 있으면 실행 중인 세션·빌드가 실패할 수 있는 강제 삭제를 확인 문구로 구분한다. 복구 섹션은 일반 후보와 분리해 원본/격리 경로, `Finder에서 열기`, `복원`만 제공하고 자동 삭제하지 않는다. 삭제 성공 후에는 실제 경로 삭제와 새 `StorageInfo` 여유 용량을 별도 표시한다.

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
- 사용 중 경고 행 + 명시적 `allowInUse` → 열린 일반 파일과 `mtime`·`atime` 변화는 허용하되 inode·소유권·종류·마운트 검증은 유지
- 격리 뒤 후보 또는 하위 디렉터리 FD/cwd가 열림 → 원위치 복원·`.refused(.inUse)`
- 사용 중 강제 삭제가 격리 중 중단된 대역 → 같은 inode의 활동 시각 변화는 허용해 원래 자리로 복원
- 격리 뒤 최종 삭제 실패 → 일반 후보에서 제거하고 복구 목록에만 유지
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
