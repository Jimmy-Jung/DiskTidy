import Darwin
import Foundation

/// `/private/tmp`·`$TMPDIR`의 최상위 엔트리 중 **안전을 증명할 수 있는 것만** 후보로 만든다.
/// 판정 불가는 전부 후보에서 뺀다 (fail-closed).
///
/// 출처를 아는 항목(Claude 세션 스크래치·Codex DerivedData·에이전트 잡파일)은 "오래됐나"가 아니라
/// "지금 쓰는 주체가 있나"로 판정한다 — `AgentWorkspace` 참고. 출처를 모르는 항목만 보존 기간 규칙을 쓴다.
enum TempScanner {
    /// 출처를 모르는 항목의 보존 기간(일). 에이전트 항목은 이 값과 무관하다.
    /// 처음엔 3일이었다. tmp의 대부분이 에이전트 작업물이 되고 그쪽은 세션 상태로 판정하게 되자,
    /// 남은 "출처 모름" 몫은 하루면 충분하다고 판단했다.
    static let defaultMinimumAgeDays = 1

    /// 격리 디렉터리는 복구 대기 항목이 들어 있으므로 일반 후보로 잡으면 안 된다.
    static let quarantineDirectoryName = ".DiskTidyQuarantine"

    /// 하위 트리 검증 깊이 상한. 넘으면 판정 불가로 보고 후보에서 뺀다.
    private static let maximumTreeDepth = 64

    enum ScanError: Error, Equatable {
        case invalidMinimumAge
        case inaccessibleRoot(String)
        case openPathQueryFailed(Int32)
        case malformedOpenPathOutput
    }

    enum Decision: Equatable {
        case eligible
        case notOwned
        case wrongType
        case tooRecent
        case inUse
        case isRoot
        case invalidConfiguration
    }

    /// 규칙 3의 두 형태.
    enum AgeRule: Equatable, Sendable {
        /// `atime`·`mtime` 둘 다 이만큼 지나야 한다. 출처 모르는 항목용 —
        /// mtime만 보면 "한 번 쓰고 계속 읽는" 파일을 날린다.
        case cold(seconds: Int64)
        /// `mtime`만 본다. 읽는 주체(에이전트 프로세스)는 세션·프로세스·열린 파일 검사가 잡는다.
        /// atime까지 보면 우리 `du`가 방금 만든 파일의 atime을 건드려 영영 후보가 되지 않는다(문서 실측).
        ///
        /// 이 규칙의 트리 안에서는 **심볼릭 링크를 허용한다**(링크 자체만 지운다). 에이전트 스크래치는
        /// 소스 트리를 통째로 복사해 두는 일이 흔해 상대 링크가 섞여 있고(실측: 602MB 세션이 링크
        /// 10개 때문에 영영 후보가 되지 않았다), `removeItem`은 링크를 따라가지 않는다 — 테스트로 고정.
        /// 최상위 후보 자체가 링크인 것은 여전히 거른다.
        case quiet(seconds: Int64)

        /// 트리 안 심볼릭 링크를 링크로만 취급해 지울 수 있는지.
        var allowsSymbolicLinksInTree: Bool {
            if case .quiet = self { return true }
            return false
        }

        static func days(_ days: Int) -> AgeRule { .cold(seconds: Int64(days) * 86_400) }

        var thresholdNanoseconds: Int64 {
            switch self {
            case .cold(let seconds), .quiet(let seconds): return seconds * 1_000_000_000
            }
        }
    }

    /// 검증을 통과한 엔트리. 크기는 나중에 `du`로 한 번에 채운다.
    private struct Verified {
        let name: String
        let path: String
        let status: stat
        let kind: TempCandidateKind
        let evidence: String
        let isInUse: Bool
    }

    // MARK: - 스캔

    /// `lsof` 또는 루트 열거 실패는 빈 목록이 아니라 throw다.
    /// 빈 목록을 돌려주면 "정리할 게 없다"와 "확인에 실패했다"가 구분되지 않는다.
    ///
    /// - Parameter live: 살아 있는 에이전트 세션·프로세스. 테스트가 가짜를 넣는다.
    static func scan(
        minimumAgeDays: Int = defaultMinimumAgeDays,
        live: LiveAgentState = .current()
    ) throws -> [TempCandidate] {
        guard isValidMinimumAge(minimumAgeDays) else { throw ScanError.invalidMinimumAge }
        let otherRule = AgeRule.days(minimumAgeDays)

        let policy = TempRootPolicy.production
        let openPaths = try relevantOpenPaths(policy: policy)
        let rootSet = policy.rootSet
        let now = Date()

        var verified: [Verified] = []
        for root in policy.roots {
            // 루트의 device를 잡아 두고 자식이 같은 볼륨인지 대조한다. 마운트 포인트를
            // 품은 디렉터리는 rename이 성공하므로(실측), 그대로 두면 격리로 옮겨진 뒤
            // 재귀 삭제가 마운트된 볼륨 내용까지 지운다.
            var rootStatus = stat()
            guard lstat(root, &rootStatus) == 0,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                throw ScanError.inaccessibleRoot(root)
            }

            for name in names where name != quarantineDirectoryName {
                // 루트가 canonical이고 심볼릭 링크는 `.wrongType`으로 걸러지므로
                // 자식 경로도 canonical이다. 엔트리마다 realpath를 부를 필요가 없다.
                let path = root + "/" + name

                var status = stat()
                guard lstat(path, &status) == 0, status.st_dev == rootStatus.st_dev else { continue }
                let isDirectory = status.st_mode & S_IFMT == S_IFDIR

                // Claude Code 스크래치 루트는 통째로 후보가 아니다. 안의 세션 디렉터리 단위로 내려간다 —
                // 통째로 잡으면 지금 돌고 있는 세션의 작업 파일까지 함께 날린다.
                if isDirectory, name == AgentWorkspace.claudeRootName, status.st_uid == getuid() {
                    verified += claudeSessions(
                        under: path, device: rootStatus.st_dev, rootPaths: rootSet,
                        openPaths: openPaths, now: now, live: live
                    )
                    continue
                }

                let kind = AgentWorkspace.classify(name: name, isDirectory: isDirectory, path: path)
                if let reason = AgentWorkspace.blockingReason(for: kind, path: path, live: live) {
                    // 사용 중인 에이전트 작업물은 왜 안 지워지는지 보이게 비활성 행으로 올린다.
                    // 잡파일까지 올리면 목록이 1바이트 파일로 덮이므로 큰 것만.
                    if kind.group == .codexDerivedData {
                        verified.append(Verified(
                            name: name, path: path, status: status, kind: kind, evidence: reason, isInUse: true
                        ))
                    }
                    continue
                }

                let rule = kind.group == .other ? otherRule : kind.ageRule
                guard decide(
                    stat: status, path: path, rootPaths: rootSet,
                    openPaths: openPaths, now: now, ageRule: rule
                ) == .eligible else { continue }

                if isDirectory,
                   !isTreeSafe(
                       at: path, device: rootStatus.st_dev, openPaths: openPaths, now: now, ageRule: rule
                   ) { continue }

                verified.append(Verified(
                    name: name, path: path, status: status, kind: kind, evidence: kind.evidence, isInUse: false
                ))
            }
        }

        let urls = verified.map { URL(fileURLWithPath: $0.path) }
        let sizes = DiskScanner.sizes(of: urls)
        return zip(verified, urls)
            .map { entry, url in
                TempCandidate(
                    name: entry.name,
                    path: url,
                    canonicalPath: entry.path,
                    sizeBytes: sizes[url] ?? 0,
                    modifiedDate: FileTimestamp(entry.status.st_mtimespec).date,
                    identity: FileIdentity(entry.status),
                    kind: entry.kind,
                    evidence: entry.evidence,
                    isInUse: entry.isInUse
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// `claude-<uid>/<프로젝트 슬러그>/<세션 UUID>` 두 단계를 내려가 세션 디렉터리를 후보 단위로 삼는다.
    /// 살아 있는 세션은 판정하지 않고 사용 중 행으로 올린다. 슬러그 디렉터리는 후보가 아니다.
    private static func claudeSessions(
        under claudeRoot: String,
        device: dev_t,
        rootPaths: Set<String>,
        openPaths: Set<String>,
        now: Date,
        live: LiveAgentState
    ) -> [Verified] {
        var found: [Verified] = []
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: claudeRoot)) ?? []
        for project in projects {
            let projectPath = claudeRoot + "/" + project
            var projectStatus = stat()
            guard lstat(projectPath, &projectStatus) == 0,
                  projectStatus.st_mode & S_IFMT == S_IFDIR,
                  projectStatus.st_dev == device,
                  projectStatus.st_uid == getuid() else { continue }

            let sessions = (try? FileManager.default.contentsOfDirectory(atPath: projectPath)) ?? []
            for session in sessions where AgentWorkspace.isSessionID(session) {
                let path = projectPath + "/" + session
                var status = stat()
                guard lstat(path, &status) == 0,
                      status.st_dev == device,
                      status.st_mode & S_IFMT == S_IFDIR else { continue }

                let kind = TempCandidateKind.claudeSession(id: session)
                let name = AgentWorkspace.claudeSessionDisplayName(project: project, sessionID: session)
                if let reason = AgentWorkspace.blockingReason(for: kind, path: path, live: live) {
                    found.append(Verified(
                        name: name, path: path, status: status, kind: kind, evidence: reason, isInUse: true
                    ))
                    continue
                }

                let rule = kind.ageRule
                guard decide(
                    stat: status, path: path, rootPaths: rootPaths,
                    openPaths: openPaths, now: now, ageRule: rule
                ) == .eligible,
                    isTreeSafe(at: path, device: device, openPaths: openPaths, now: now, ageRule: rule)
                else { continue }

                found.append(Verified(
                    name: name, path: path, status: status, kind: kind, evidence: kind.evidence, isInUse: false
                ))
            }
        }
        return found
    }

    // MARK: - 규칙 4: 열린 경로

    /// 사용자 프로세스 전체의 열린 경로. canonical 표기로 정규화해 돌려준다.
    /// 실행·파싱 실패는 throw다. 빈 Set은 "열린 경로 없음"만 뜻한다.
    ///
    /// `lsof +D <root>`는 26GB 트리를 전수 순회하므로 못 쓴다. 사용자 uid 기준으로
    /// 한 번만 부르고(실측 1.2초, 약 89,000 필드) 그 스냅샷을 스캔 내내 재사용한다.
    static func openPaths() throws -> Set<String> {
        let result = ShellRunner.run(
            "/usr/sbin/lsof", ["-w", "-n", "-F0n", "-u", String(getuid())]
        )
        guard result.succeeded else { throw ScanError.openPathQueryFailed(result.exitCode) }
        return try parseOpenPaths(result.output)
    }

    /// `-F0n`은 NUL 종료 필드 출력이다. 레코드 종결 개행은 **다음 필드 앞**에 붙어 오므로
    /// 선행 개행만 걷어낸다. 줄 단위로 나누면 줄바꿈이 든 파일명에서 필드가 깨진다.
    static func parseOpenPaths(_ output: String) throws -> Set<String> {
        var paths: Set<String> = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let value = field.drop { $0 == "\n" }
            // `nTCP 127.0.0.1:8080` 같은 비경로가 섞여 온다. `n/`로 시작할 때만 취한다.
            guard value.hasPrefix("n/") else { continue }
            paths.insert(CanonicalPath.normalizingPrefix(String(value.dropFirst())))
        }

        // 사용자 프로세스가 하나라도 살아 있으면 열린 경로는 반드시 나온다.
        // 0건은 파싱이 깨졌다는 뜻이므로 빈 집합으로 넘기지 않는다.
        guard !paths.isEmpty else { throw ScanError.malformedOpenPathOutput }
        return paths
    }

    /// 루트 밖 경로는 판정에 쓰이지 않는다. 89,000개를 그대로 들고 다니면
    /// 디렉터리 후보마다 전수 접두사 검사를 돌게 된다.
    /// 루트 경로 **자신**은 담지 않는다. 루트는 규칙 5에서 먼저 걸러지므로 어떤 판정에도
    /// 쓰이지 않는다. 남겨 두면 "이 집합의 원소는 전부 루트 하위"라는 불변식이 깨진다.
    static func relevantOpenPaths(policy: TempRootPolicy) throws -> Set<String> {
        let all = try openPaths()
        return all.filter { policy.root(containing: $0) != nil }
    }

    // MARK: - 순수 판정 로직

    /// 파일시스템 없이 검증할 수 있도록 순수 함수로 뺐다.
    /// `stat`을 손으로 만들면 소유자·타입·시각 조합 전부를 실제 파일 없이 시험할 수 있다.
    static func decide(
        stat status: stat,
        path: String,
        rootPaths: Set<String>,
        openPaths: Set<String>,
        now: Date,
        ageRule: AgeRule
    ) -> Decision {
        // canonicalize에 실패한 경로가 여기까지 오면 경계 검사를 신뢰할 수 없다.
        guard path.hasPrefix("/") else { return .invalidConfiguration }

        // 규칙 5: 루트 자체를 통째로 지우는 사고 방지.
        guard !rootPaths.contains(path) else { return .isRoot }

        // 규칙 1: `/tmp`은 공용 디렉터리다. root·타 데몬 소유 파일이 섞여 있고 지울 권한도 없다.
        guard status.st_uid == getuid() else { return .notOwned }

        // 규칙 2: 소켓·FIFO·심볼릭 링크 제외. VS Code 소켓을 지우면 그 앱이 즉시 깨진다.
        let type = status.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return .wrongType }

        // 자식을 unlink하려면 부모 디렉터리에 쓰기 권한이 필요하다. r-x 디렉터리는 열거만
        // 되고 삭제는 EACCES라, removeItem이 형제 파일 일부를 지운 뒤 멈춘다(실측).
        // 그 시점에 mtime이 바뀌어 identity 대조가 복원까지 막는다.
        guard type != S_IFDIR || status.st_mode & S_IWUSR != 0 else { return .wrongType }

        // 규칙 3: `.cold`는 mtime·atime 둘 다, `.quiet`는 mtime만 — 이유는 `AgeRule` 주석.
        let threshold = ageRule.thresholdNanoseconds
        let elapsed = nanoseconds(since: now)
        guard elapsed(FileTimestamp(status.st_mtimespec)) > threshold else { return .tooRecent }
        if case .cold = ageRule {
            guard elapsed(FileTimestamp(status.st_atimespec)) > threshold else { return .tooRecent }
        }

        // 규칙 4는 양방향이다. 디렉터리는 안의 파일 하나만 열려 있어도 통째로 지우면 안 된다.
        guard !openPaths.contains(path) else { return .inUse }
        if type == S_IFDIR {
            // 경계 판정은 CanonicalPath 한 곳에만 둔다. String.hasPrefix는 grapheme
            // 단위라 결합문자로 시작하는 이름에서 하위 경로를 놓친다.
            guard !openPaths.contains(where: { CanonicalPath.contains(path, $0) }) else {
                return .inUse
            }
        }

        return .eligible
    }

    /// 보존 기간(일)로 부르는 예전 형태. `.cold` 규칙으로 옮긴다.
    static func decide(
        stat status: stat,
        path: String,
        rootPaths: Set<String>,
        openPaths: Set<String>,
        now: Date,
        minimumAgeDays: Int
    ) -> Decision {
        guard isValidMinimumAge(minimumAgeDays) else { return .invalidConfiguration }
        return decide(
            stat: status, path: path, rootPaths: rootPaths,
            openPaths: openPaths, now: now, ageRule: .days(minimumAgeDays)
        )
    }

    /// 상한이 없으면 `minimumAgeDays * 86_400 * 1_000_000_000`이 Int64를 넘어 트랩한다.
    static func isValidMinimumAge(_ days: Int) -> Bool { (0 ... 100_000).contains(days) }

    /// 최상위 `lstat`만 보고 재귀 삭제하면, 사용자 소유 디렉터리 안의 타 UID 파일·소켓·
    /// 열린 파일까지 함께 지운다. 하위 전체에 규칙 1~4를 적용하고 하나라도 어긋나면 제외한다.
    static func isTreeSafe(
        at path: String,
        device: dev_t,
        openPaths: Set<String>,
        now: Date,
        ageRule: AgeRule,
        depth: Int = 0
    ) -> Bool {
        guard depth < maximumTreeDepth else { return false }
        // 권한 오류로 열거하지 못하는 디렉터리는 안전을 증명할 수 없다.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }

        for name in names {
            let child = path + "/" + name
            var status = stat()
            guard lstat(child, &status) == 0 else { return false }
            // 마운트 경계를 넘지 않는다. 넘으면 남의 볼륨 내용을 재귀 삭제하게 된다.
            guard status.st_dev == device else { return false }
            // 에이전트 트리의 심볼릭 링크는 링크만 지운다. 따라가지 않으므로 대상은 검사할 필요가 없다 —
            // `lstat`이라 여기 든 소유자·시각도 링크 자신의 것이다.
            if status.st_mode & S_IFMT == S_IFLNK, ageRule.allowsSymbolicLinksInTree,
               status.st_uid == getuid() { continue }
            // rootPaths를 비워 넘긴다. 하위 항목은 루트일 수 없다.
            guard decide(
                stat: status, path: child, rootPaths: [],
                openPaths: openPaths, now: now, ageRule: ageRule
            ) == .eligible else { return false }

            if status.st_mode & S_IFMT == S_IFDIR,
               !isTreeSafe(
                   at: child, device: device, openPaths: openPaths, now: now,
                   ageRule: ageRule, depth: depth + 1
               ) { return false }
        }
        return true
    }

    /// 보존 기간(일)로 부르는 예전 형태.
    static func isTreeSafe(
        at path: String,
        device: dev_t,
        openPaths: Set<String>,
        now: Date,
        minimumAgeDays: Int,
        depth: Int = 0
    ) -> Bool {
        guard isValidMinimumAge(minimumAgeDays) else { return false }
        return isTreeSafe(
            at: path, device: device, openPaths: openPaths, now: now,
            ageRule: .days(minimumAgeDays), depth: depth
        )
    }

    /// `Date`를 그대로 Double로 곱해 나노초를 만들면 1e18 근처에서 정밀도가 날아가
    /// "정확히 N일" 경계가 흔들린다. 정수부와 소수부를 나눠 더한다.
    private static func nanoseconds(since now: Date) -> (FileTimestamp) -> Int64 {
        let epoch = now.timeIntervalSince1970
        let whole = epoch.rounded(.down)
        let nowNanos = Int64(whole) * 1_000_000_000
            + Int64(((epoch - whole) * 1_000_000_000).rounded())
        return { timestamp in
            // 파일시스템은 극단 tv_sec을 그대로 받아 저장한다(실측: utimes(-9223372037) 성공).
            // 곱셈이 Int64를 넘으면 Swift가 트랩해 앱이 죽으므로, 범위 밖은 판정 불가로 보고
            // "방금 만든 것"처럼 취급한다 — 후보에서 빠진다(fail-closed).
            guard (-7_000_000_000 ... 7_000_000_000).contains(timestamp.seconds) else {
                return Int64.min
            }
            return nowNanos - (timestamp.seconds * 1_000_000_000 + timestamp.nanoseconds)
        }
    }
}
