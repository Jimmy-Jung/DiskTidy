import Darwin
import Foundation

/// `/private/tmp`·`$TMPDIR`의 최상위 엔트리 중 **안전을 증명할 수 있는 것만** 후보로 만든다.
/// 판정 불가는 전부 후보에서 뺀다 (fail-closed).
enum TempScanner {
    /// v1 고정 보존 기간: 3일.
    static let defaultMinimumAgeDays = 3

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

    // MARK: - 스캔

    /// `lsof` 또는 루트 열거 실패는 빈 목록이 아니라 throw다.
    /// 빈 목록을 돌려주면 "정리할 게 없다"와 "확인에 실패했다"가 구분되지 않는다.
    static func scan(minimumAgeDays: Int = defaultMinimumAgeDays) throws -> [TempCandidate] {
        guard isValidMinimumAge(minimumAgeDays) else { throw ScanError.invalidMinimumAge }

        let policy = TempRootPolicy.production
        let openPaths = try relevantOpenPaths(policy: policy)
        let rootSet = policy.rootSet
        let now = Date()

        // 크기는 `du`를 한 번에 묶어 부르므로, 검증을 모두 끝낸 뒤에 채운다.
        var verified: [(name: String, path: String, status: stat)] = []
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
                guard decide(
                    stat: status, path: path, rootPaths: rootSet,
                    openPaths: openPaths, now: now, minimumAgeDays: minimumAgeDays
                ) == .eligible else { continue }

                if status.st_mode & S_IFMT == S_IFDIR,
                   !isTreeSafe(
                       at: path, device: rootStatus.st_dev, openPaths: openPaths,
                       now: now, minimumAgeDays: minimumAgeDays
                   ) { continue }

                verified.append((name, path, status))
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
                    identity: FileIdentity(entry.status)
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
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
        minimumAgeDays: Int
    ) -> Decision {
        guard isValidMinimumAge(minimumAgeDays) else { return .invalidConfiguration }
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

        // 규칙 3: mtime만 보면 "한 번 쓰고 계속 읽는" 파일을 날린다. 둘 다 넘어야 한다.
        let threshold = Int64(minimumAgeDays) * 86_400 * 1_000_000_000
        let elapsed = nanoseconds(since: now)
        guard elapsed(FileTimestamp(status.st_mtimespec)) > threshold,
              elapsed(FileTimestamp(status.st_atimespec)) > threshold else { return .tooRecent }

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

    /// 상한이 없으면 `minimumAgeDays * 86_400 * 1_000_000_000`이 Int64를 넘어 트랩한다.
    static func isValidMinimumAge(_ days: Int) -> Bool { (0 ... 100_000).contains(days) }

    /// 최상위 `lstat`만 보고 재귀 삭제하면, 사용자 소유 디렉터리 안의 타 UID 파일·소켓·
    /// 열린 파일까지 함께 지운다. 하위 전체에 규칙 1~4를 적용하고 하나라도 어긋나면 제외한다.
    static func isTreeSafe(
        at path: String,
        device: dev_t,
        openPaths: Set<String>,
        now: Date,
        minimumAgeDays: Int,
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
            // rootPaths를 비워 넘긴다. 하위 항목은 루트일 수 없다.
            guard decide(
                stat: status, path: child, rootPaths: [],
                openPaths: openPaths, now: now, minimumAgeDays: minimumAgeDays
            ) == .eligible else { return false }

            if status.st_mode & S_IFMT == S_IFDIR,
               !isTreeSafe(
                   at: child, device: device, openPaths: openPaths, now: now,
                   minimumAgeDays: minimumAgeDays, depth: depth + 1
               ) { return false }
        }
        return true
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
