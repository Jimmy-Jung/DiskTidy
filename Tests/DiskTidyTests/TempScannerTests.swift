import Darwin
import Foundation
import Testing

@testable import DiskTidy

// MARK: - 헬퍼

private let day: TimeInterval = 86_400

/// 실제 파일 없이 규칙 조합을 시험하려면 `stat`을 손으로 조립해야 한다.
private func makeStat(
    uid: uid_t = getuid(),
    mode: mode_t = S_IFREG | 0o644,
    modified: Date,
    accessed: Date? = nil,
    inode: UInt64 = 1,
    device: Int32 = 1
) -> stat {
    var status = stat()
    status.st_uid = uid
    status.st_mode = mode
    status.st_ino = inode
    status.st_dev = device
    status.st_mtimespec = timespec(
        tv_sec: Int(modified.timeIntervalSince1970.rounded(.down)), tv_nsec: 0
    )
    status.st_atimespec = timespec(
        tv_sec: Int((accessed ?? modified).timeIntervalSince1970.rounded(.down)), tv_nsec: 0
    )
    return status
}

private enum FixtureError: Error {
    case unreachable(String)
}

/// atime과 mtime을 함께 과거로 돌린다. mtime만 바꾸면 규칙 3의 회귀 테스트가 성립하지 않는다.
private func setTimestamps(of url: URL, ageInDays: Double) throws {
    let target = Date().addingTimeInterval(-ageInDays * day).timeIntervalSince1970
    var times = [
        timeval(tv_sec: Int(target.rounded(.down)), tv_usec: 0),
        timeval(tv_sec: Int(target.rounded(.down)), tv_usec: 0)
    ]
    guard utimes(url.path, &times) == 0 else {
        throw FixtureError.unreachable("utimes 실패 \(url.path)")
    }
}

/// 스캐너와 같은 방식으로 실제 파일에서 후보를 만든다.
private func makeCandidate(for url: URL, canonicalPath: String? = nil) throws -> TempCandidate {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw FixtureError.unreachable("lstat 실패 \(url.path)")
    }
    return TempCandidate(
        name: url.lastPathComponent,
        path: url,
        canonicalPath: canonicalPath ?? url.path,
        sizeBytes: 0,
        modifiedDate: FileTimestamp(status.st_mtimespec).date,
        identity: FileIdentity(status)
    )
}

private func identity(of url: URL) throws -> FileIdentity {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw FixtureError.unreachable("lstat 실패 \(url.path)")
    }
    return FileIdentity(status)
}

private var userTempRoot: String {
    get throws {
        guard let root = CanonicalPath.resolve(NSTemporaryDirectory()),
              TempRootPolicy.production.isRoot(root) else {
            throw FixtureError.unreachable("$TMPDIR이 production root가 아니다")
        }
        return root
    }
}

// MARK: - 순수 판정

@Suite("TempScanner 판정")
struct TempScannerDecisionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let root = "/private/tmp"

    private func decide(
        _ status: stat,
        path: String = "/private/tmp/entry",
        openPaths: Set<String> = [],
        minimumAgeDays: Int = 3
    ) -> TempScanner.Decision {
        TempScanner.decide(
            stat: status, path: path, rootPaths: [root],
            openPaths: openPaths, now: now, minimumAgeDays: minimumAgeDays
        )
    }

    private func old(_ days: Double = 10) -> Date { now.addingTimeInterval(-days * day) }

    @Test("타 UID 소유는 후보가 아니다")
    func rejectsForeignOwner() {
        // `/tmp`은 공용 디렉터리다. root·타 데몬 소유 파일이 섞여 있고 지울 권한도 없다.
        #expect(decide(makeStat(uid: getuid() &+ 1, modified: old())) == .notOwned)
    }

    @Test(
        "정규 파일·디렉터리가 아니면 후보가 아니다",
        arguments: [S_IFSOCK, S_IFLNK, S_IFIFO, S_IFBLK, S_IFCHR]
    )
    func rejectsNonRegularTypes(type: mode_t) {
        #expect(decide(makeStat(mode: type | 0o600, modified: old())) == .wrongType)
    }

    @Test("mtime만 오래됐고 atime이 최근이면 후보가 아니다")
    func requiresBothTimestampsOld() {
        // mtime만 보면 "한 번 쓰고 계속 읽는" 파일을 날린다. 회귀 방지 핵심.
        let status = makeStat(modified: old(), accessed: now.addingTimeInterval(-3_600))
        #expect(decide(status) == .tooRecent)
    }

    @Test("mtime·atime이 모두 기준을 넘으면 후보다")
    func acceptsWhenBothTimestampsOld() {
        #expect(decide(makeStat(modified: old(), accessed: old())) == .eligible)
    }

    @Test("정확히 N일 경과는 후보가 아니다 (N일 초과만 허용)")
    func rejectsExactlyAtThreshold() {
        let status = makeStat(modified: old(3), accessed: old(3))
        #expect(decide(status) == .tooRecent)
    }

    @Test("N일을 1초라도 넘으면 후보다")
    func acceptsJustPastThreshold() {
        let boundary = now.addingTimeInterval(-(3 * day + 1))
        #expect(decide(makeStat(modified: boundary, accessed: boundary)) == .eligible)
    }

    @Test("미래 시각은 후보가 아니다", arguments: [true, false])
    func rejectsFutureTimestamps(isModifiedInFuture: Bool) {
        let future = now.addingTimeInterval(day)
        let status = isModifiedInFuture
            ? makeStat(modified: future, accessed: old())
            : makeStat(modified: old(), accessed: future)
        #expect(decide(status) == .tooRecent)
    }

    @Test("열린 경로와 정확히 일치하면 후보가 아니다")
    func rejectsOpenFile() {
        let status = makeStat(modified: old(), accessed: old())
        #expect(decide(status, openPaths: ["/private/tmp/entry"]) == .inUse)
    }

    @Test("디렉터리 하위 파일 하나만 열려 있어도 후보가 아니다")
    func rejectsDirectoryWithOpenChild() {
        // 디렉터리째 지우면 그 안의 열린 파일까지 사라진다. 회귀 방지 핵심.
        let status = makeStat(mode: S_IFDIR | 0o755, modified: old(), accessed: old())
        #expect(decide(status, openPaths: ["/private/tmp/entry/inner/log.txt"]) == .inUse)
    }

    @Test("이름이 겹치는 형제 디렉터리의 열린 파일은 영향이 없다")
    func ignoresSiblingWithSharedNamePrefix() {
        let status = makeStat(mode: S_IFDIR | 0o755, modified: old(), accessed: old())
        // `entry-backup`은 `entry`의 하위가 아니다. component 경계를 지켜야 한다.
        #expect(decide(status, openPaths: ["/private/tmp/entry-backup/log.txt"]) == .eligible)
    }

    @Test("루트 자체는 후보가 아니다")
    func rejectsRootItself() {
        let status = makeStat(mode: S_IFDIR | 0o755, modified: old(), accessed: old())
        #expect(decide(status, path: root) == .isRoot)
    }

    @Test("음수 보존 기간은 판정 불가다")
    func rejectsNegativeMinimumAge() {
        let status = makeStat(modified: old(), accessed: old())
        #expect(decide(status, minimumAgeDays: -1) == .invalidConfiguration)
    }

    @Test("절대 경로가 아니면 판정 불가다")
    func rejectsRelativePath() {
        let status = makeStat(modified: old(), accessed: old())
        #expect(decide(status, path: "tmp/entry") == .invalidConfiguration)
    }

    @Test("보존 기간 0일이면 1초만 지나도 후보다")
    func zeroMinimumAgeAcceptsAnyPast() {
        let past = now.addingTimeInterval(-1)
        #expect(decide(makeStat(modified: past, accessed: past), minimumAgeDays: 0) == .eligible)
    }

    @Test("Int64를 넘기는 타임스탬프에서 트랩하지 않고 후보에서 뺀다", arguments: [
        Int64(-9_223_372_037), Int64(9_223_372_036)
    ])
    func extremeTimestampsDoNotTrap(seconds: Int64) {
        // 파일시스템이 이 값을 그대로 받아 저장한다(실측 `utimes(-9223372037)` 성공).
        // 곱셈이 Int64를 넘으면 Swift가 트랩해, 후보 목록을 여는 것만으로 앱이 죽는다.
        // 회귀 방지 핵심.
        var status = makeStat(modified: now)
        status.st_mtimespec = timespec(tv_sec: Int(seconds), tv_nsec: 0)
        status.st_atimespec = timespec(tv_sec: Int(seconds), tv_nsec: 0)
        #expect(decide(status) == .tooRecent)
    }

    @Test("범위 안의 아주 오래된 시각은 정상 후보다")
    func ancientButRepresentableIsEligible() {
        // 1901년 파일은 합법이다. 오버플로 가드가 정상 판정까지 삼키면 안 된다.
        var status = makeStat(modified: now)
        status.st_mtimespec = timespec(tv_sec: Int(Int32.min) - 1, tv_nsec: 0)
        status.st_atimespec = timespec(tv_sec: Int(Int32.min) - 1, tv_nsec: 0)
        #expect(decide(status) == .eligible)
    }

    @Test("보존 기간 상한을 넘으면 판정 불가다")
    func rejectsAbsurdMinimumAge() {
        // minimumAgeDays * 86_400 * 1_000_000_000도 Int64를 넘길 수 있다.
        let status = makeStat(modified: old(), accessed: old())
        #expect(decide(status, minimumAgeDays: Int.max) == .invalidConfiguration)
        #expect(decide(status, minimumAgeDays: 100_001) == .invalidConfiguration)
        // 상한 자체는 유효한 설정이다. 판정 불가가 아니라 기간 미달이어야 한다.
        #expect(decide(status, minimumAgeDays: 100_000) == .tooRecent)
    }

    @Test("쓰기 권한 없는 디렉터리는 후보가 아니다")
    func rejectsUnwritableDirectory() {
        // 0555 디렉터리는 열거만 되고 자식 unlink는 EACCES다. removeItem이 원자적이지
        // 않아 형제 일부를 지운 뒤 멈추고, 그 시점에 복원까지 막힌다. 회귀 방지 핵심.
        let status = makeStat(mode: S_IFDIR | 0o555, modified: old(), accessed: old())
        #expect(decide(status) == .wrongType)
        #expect(decide(makeStat(mode: S_IFDIR | 0o755, modified: old(), accessed: old())) == .eligible)
        // 정규 파일은 쓰기 권한이 없어도 부모만 쓸 수 있으면 지워진다.
        #expect(decide(makeStat(mode: S_IFREG | 0o444, modified: old(), accessed: old())) == .eligible)
    }
}

// MARK: - lsof 파싱

@Suite("lsof 출력 파싱")
struct OpenPathParsingTests {
    @Test("NUL 종료 필드에서 경로만 골라낸다")
    func takesOnlyPathFields() throws {
        let output = "p1234\0fcwd\0n/private/tmp/foo\0f3\0nTCP 127.0.0.1:8080\0"
        #expect(try TempScanner.parseOpenPaths(output) == ["/private/tmp/foo"])
    }

    @Test("레코드 종결 개행이 섞여도 필드가 깨지지 않는다")
    func toleratesRecordTerminators() throws {
        // 실제 lsof 출력은 각 레코드 끝에 NUL + NL을 붙인다.
        let output = "p425\0\nfcwd\0n/private/tmp/a\0\nftxt\0n/private/tmp/b\0\n"
        #expect(try TempScanner.parseOpenPaths(output) == ["/private/tmp/a", "/private/tmp/b"])
    }

    @Test("줄바꿈이 든 파일명도 한 필드로 보존한다")
    func preservesNewlineInsidePath() throws {
        let output = "p1\0n/private/tmp/we\nird\0\nf2\0n/private/tmp/plain\0\n"
        let parsed = try TempScanner.parseOpenPaths(output)
        #expect(parsed.contains("/private/tmp/we\nird"))
        #expect(parsed.contains("/private/tmp/plain"))
    }

    @Test("경로 표기를 canonical로 맞춘다")
    func normalizesPathNotation() throws {
        let parsed = try TempScanner.parseOpenPaths("p1\0n/tmp/x\0\nf2\0n/var/folders/a/T/y\0\n")
        #expect(parsed == ["/private/tmp/x", "/private/var/folders/a/T/y"])
    }

    @Test("경로 필드가 하나도 없으면 빈 집합이 아니라 오류다")
    func emptyResultIsAnError() {
        // 빈 집합을 "열린 파일 없음"으로 오인하면 사용 중인 파일이 후보로 올라온다.
        #expect(throws: TempScanner.ScanError.malformedOpenPathOutput) {
            _ = try TempScanner.parseOpenPaths("p1\0fcwd\0nTCP 1.2.3.4:80\0\n")
        }
    }

    @Test("실제 lsof는 절대 경로 집합을 준다")
    func realQueryReturnsAbsolutePaths() throws {
        // `allSatisfy { hasPrefix("/") }`만 보면 파서가 `n/`만 취하므로 항상 참이라
        // 아무것도 검증하지 못한다. 실제로 열어 둔 경로가 잡히는지 봐야 한다.
        let temp = try TempDirectory()
        let file = try temp.makeFile("held-by-lsof.bin", bytes: 16)
        let descriptor = open(file.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let paths = try TempScanner.openPaths()
        #expect(!paths.isEmpty)
        #expect(paths.contains(CanonicalPath.normalizingPrefix(file.path)))
    }

    @Test("루트 밖 경로는 판정 집합에서 걸러낸다")
    func filtersOpenPathsToRoots() throws {
        // 89,000개를 그대로 들고 다니면 디렉터리 후보마다 전수 접두사 검사를 돈다.
        let temp = try TempDirectory()
        let inside = try temp.makeFile("inside-root.bin", bytes: 16)
        let descriptor = open(inside.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let policy = TempRootPolicy.production
        let relevant = try TempScanner.relevantOpenPaths(policy: policy)
        #expect(relevant.contains(CanonicalPath.normalizingPrefix(inside.path)))
        // 걸러낸 뒤에는 루트 하위 경로만 남아야 한다.
        #expect(relevant.allSatisfy { policy.root(containing: $0) != nil })
        #expect(relevant.count < (try TempScanner.openPaths()).count)
    }
}

// MARK: - 경로 경계

@Suite("경로 경계와 루트 정책")
struct PathBoundaryTests {
    @Test("component 경계로 하위 여부를 가린다")
    func containsUsesComponentBoundary() {
        #expect(CanonicalPath.contains("/private/tmp", "/private/tmp/x"))
        // 단순 hasPrefix면 여기서 뚫린다.
        #expect(!CanonicalPath.contains("/private/tmp", "/private/tmp2/x"))
        #expect(!CanonicalPath.contains("/private/tmp", "/private/tmp"))
        #expect(CanonicalPath.contains("/private/tmp/", "/private/tmp/x"))
    }

    @Test("갈라지는 접두사만 canonical 표기로 맞춘다")
    func normalizesOnlyDivergingPrefixes() {
        #expect(CanonicalPath.normalizingPrefix("/tmp/x") == "/private/tmp/x")
        #expect(CanonicalPath.normalizingPrefix("/tmp") == "/private/tmp")
        #expect(CanonicalPath.normalizingPrefix("/var/folders/a") == "/private/var/folders/a")
        #expect(CanonicalPath.normalizingPrefix("/private/tmp/x") == "/private/tmp/x")
        #expect(CanonicalPath.normalizingPrefix("/tmpfile") == "/tmpfile")
        #expect(CanonicalPath.normalizingPrefix("/Users/x") == "/Users/x")
    }

    @Test("production 루트는 `/`·홈을 포함하지 않는다")
    func productionRootsAreSafe() throws {
        let policy = TempRootPolicy.production
        #expect(!policy.roots.isEmpty)
        #expect(!policy.roots.contains("/"))
        #expect(!policy.roots.contains(NSHomeDirectory()))
        #expect(policy.roots.allSatisfy { $0.hasPrefix("/") })
        #expect(policy.roots.contains("/private/tmp"))
        #expect(policy.roots.contains(try userTempRoot))
        // 중복 제거가 되어 있어야 한다.
        #expect(Set(policy.roots).count == policy.roots.count)
    }

    @Test("루트 자체는 하위가 아니다")
    func rootIsNotItsOwnDescendant() {
        let policy = TempRootPolicy.production
        #expect(policy.isRoot("/private/tmp"))
        // 경계 판정 진입점은 root(containing:) 하나뿐이다.
        #expect(policy.root(containing: "/private/tmp") == nil)
        #expect(policy.root(containing: "/private/tmp/anything") == "/private/tmp")
        #expect(policy.root(containing: "/Users/somebody/file") == nil)
    }

    @Test("루트가 될 수 없는 경로를 거부한다")
    func rejectsUnsafeRootCandidates() throws {
        // 루트를 추가하는 다음 사람이 홈 전체를 완전 삭제 대상으로 만들지 못하게 막는다.
        #expect(TempRootPolicy.validated("/") == nil)
        #expect(TempRootPolicy.validated(NSHomeDirectory()) == nil)
        #expect(TempRootPolicy.validated("") == nil)
        #expect(TempRootPolicy.validated("tmp") == nil)                  // 상대 경로
        #expect(TempRootPolicy.validated("/nope-\(UUID().uuidString)") == nil)

        // 디렉터리가 아니면 루트가 아니다.
        let temp = try TempDirectory()
        let file = try temp.makeFile("not-a-directory.bin", bytes: 8)
        #expect(TempRootPolicy.validated(file.path) == nil)

        // 유효한 루트는 canonical 표기로 돌아온다.
        #expect(TempRootPolicy.validated("/tmp") == "/private/tmp")
        #expect(TempRootPolicy.validated("/private/tmp") == "/private/tmp")
    }

    @Test("결합문자로 시작하는 이름도 하위로 인식한다")
    func combiningMarkDoesNotBreakBoundary() {
        // String.hasPrefix는 grapheme 단위라 `/` + U+0301이 한 글자로 합쳐진다.
        // 그러면 진짜 하위 경로가 "하위 아님"이 되어 규칙 4가 죽는다. 회귀 방지 핵심.
        let weird = "/private/tmp/\u{0301}oops"
        #expect(!weird.hasPrefix("/private/tmp/"))
        #expect(CanonicalPath.contains("/private/tmp", weird))
        #expect(TempRootPolicy.production.root(containing: weird) == "/private/tmp")
    }
}

// MARK: - 하위 트리 검증

@Suite("디렉터리 하위 트리 검증")
struct TreeSafetyTests {
    private let temp: TempDirectory
    private let now = Date()

    init() throws { temp = try TempDirectory() }

    private func isSafe(_ url: URL, openPaths: Set<String> = []) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return TempScanner.isTreeSafe(
            at: url.path, device: status.st_dev, openPaths: openPaths,
            now: now, minimumAgeDays: 3
        )
    }

    @discardableResult
    private func makeOldTree() throws -> URL {
        try temp.makeFile("tree/a.log", bytes: 8)
        try temp.makeFile("tree/nested/b.log", bytes: 8)
        // 부모를 나중에 손대면 자식 타임스탬프가 다시 최근이 되지 않게 아래부터 올라간다.
        for path in ["tree/nested/b.log", "tree/a.log", "tree/nested", "tree"] {
            try setTimestamps(of: temp.url.appendingPathComponent(path), ageInDays: 10)
        }
        return temp.url.appendingPathComponent("tree")
    }

    @Test("오래된 정규 파일만 있으면 안전하다")
    func acceptsOldRegularFiles() throws {
        #expect(isSafe(try makeOldTree()))
    }

    @Test("빈 디렉터리는 안전하다")
    func acceptsEmptyDirectory() throws {
        let empty = try temp.makeDirectory("empty")
        try setTimestamps(of: empty, ageInDays: 10)
        #expect(isSafe(empty))
    }

    @Test("FIFO가 하나라도 있으면 안전하지 않다")
    func rejectsFifoInTree() throws {
        let tree = try makeOldTree()
        let fifo = tree.appendingPathComponent("nested/pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try setTimestamps(of: fifo, ageInDays: 10)
        #expect(!isSafe(tree))
    }

    @Test("심볼릭 링크가 있으면 안전하지 않다")
    func rejectsSymbolicLinkInTree() throws {
        let tree = try makeOldTree()
        try temp.makeSymbolicLink(
            "tree/nested/link", to: FileManager.default.homeDirectoryForCurrentUser
        )
        #expect(!isSafe(tree))
    }

    @Test("최근에 만진 하위 파일이 있으면 안전하지 않다")
    func rejectsRecentChild() throws {
        let tree = try makeOldTree()
        try setTimestamps(of: tree.appendingPathComponent("nested/b.log"), ageInDays: 0)
        #expect(!isSafe(tree))
    }

    @Test("마운트 경계를 넘는 하위 항목이 있으면 안전하지 않다")
    func rejectsCrossDeviceChild() throws {
        // 마운트 포인트를 품은 디렉터리는 rename이 성공한다(실측). 경계를 안 보면
        // 재귀 삭제가 마운트된 볼륨 내용까지 지운다. 회귀 방지 핵심.
        let tree = try makeOldTree()
        #expect(isSafe(tree))
        // 루트와 다른 device를 넘기면 모든 자식이 경계 밖으로 판정돼야 한다.
        #expect(
            !TempScanner.isTreeSafe(
                at: tree.path, device: 0, openPaths: [], now: now, minimumAgeDays: 3
            )
        )
    }

    @Test("하위 파일이 열려 있으면 안전하지 않다")
    func rejectsOpenChild() throws {
        let tree = try makeOldTree()
        let opened = tree.appendingPathComponent("nested/b.log").path
        #expect(!isSafe(tree, openPaths: [opened]))
    }

    @Test("깊이 상한을 넘는 트리는 판정 불가로 제외한다")
    func rejectsTreeDeeperThanLimit() throws {
        // 상한이 없으면 재귀가 스택을 태운다. 넘으면 안전을 증명하지 못한 것으로 본다.
        func makeChain(_ name: String, depth: Int) throws -> URL {
            let relative = ([name] + Array(repeating: "d", count: depth)).joined(separator: "/")
            try temp.makeDirectory(relative)
            // 부모를 나중에 손대야 자식 생성이 부모 타임스탬프를 되돌리지 않는다.
            var components = relative.split(separator: "/").map(String.init)
            while !components.isEmpty {
                try setTimestamps(
                    of: temp.url.appendingPathComponent(components.joined(separator: "/")),
                    ageInDays: 10
                )
                components.removeLast()
            }
            return temp.url.appendingPathComponent(name)
        }

        #expect(isSafe(try makeChain("shallow", depth: 60)))
        #expect(!isSafe(try makeChain("deep", depth: 70)))
    }

    @Test("열거할 수 없는 하위 디렉터리가 있으면 안전하지 않다")
    func rejectsUnreadableSubdirectory() throws {
        let tree = try makeOldTree()
        let locked = tree.appendingPathComponent("nested")
        #expect(chmod(locked.path, 0o000) == 0)
        defer { chmod(locked.path, 0o755) }
        // 권한 오류로 내용을 볼 수 없으면 안전을 증명할 수 없다.
        #expect(!isSafe(tree))
    }
}

// MARK: - 완전 삭제 경계

@Suite("PermanentDeleter 경계")
struct PermanentDeleterTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    /// production root(`$TMPDIR`) 안에 3일 넘은 파일을 만든다.
    private func makeStaleFile(_ name: String, bytes: Int = 64) throws -> URL {
        let file = try temp.makeFile(name, bytes: bytes)
        try setTimestamps(of: file, ageInDays: 10)
        return file
    }

    @Test("production root 안의 오래된 파일은 실제로 사라진다")
    func deletesStaleFileInsideRoot() throws {
        let file = try makeStaleFile("delete-me.bin")
        #expect(PermanentDeleter.delete(try makeCandidate(for: file)) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("production root 밖의 파일은 거부하고 그대로 둔다")
    func refusesOutsideProductionRoot() throws {
        // 회귀 방지 핵심. 루트 밖으로 완전 삭제가 나가면 되돌릴 방법이 없다.
        let outsideRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/DiskTidyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }

        let file = outsideRoot.appendingPathComponent("keep.bin")
        try Data(repeating: 0x41, count: 32).write(to: file)
        try setTimestamps(of: file, ageInDays: 10)

        #expect(
            PermanentDeleter.delete(try makeCandidate(for: file))
                == .refused(.outsideProductionRoot)
        )
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("`/tmp` 표기와 `/private/tmp` 표기는 같은 판정을 받는다")
    func treatsBothNotationsIdentically() throws {
        let file = try makeStaleFile("notation.bin")
        // TempDirectory는 `/var/folders/...` 표기를 쓴다. canonical 표기로 바꿔 넣어도
        // 같은 대상이므로 같은 결과여야 한다.
        let canonical = CanonicalPath.normalizingPrefix(file.path)
        #expect(canonical.hasPrefix("/private/"))

        let candidate = try makeCandidate(for: file, canonicalPath: canonical)
        #expect(PermanentDeleter.delete(candidate) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("루트 자체는 거부한다")
    func refusesRootItself() throws {
        let root = try userTempRoot
        let candidate = try makeCandidate(for: URL(fileURLWithPath: root), canonicalPath: root)
        #expect(PermanentDeleter.delete(candidate) == .refused(.outsideProductionRoot))
        #expect(FileManager.default.fileExists(atPath: root))
    }

    @Test("격리 디렉터리 하위는 거부한다")
    func refusesQuarantineItself() throws {
        let quarantine = try userTempRoot + "/" + TempScanner.quarantineDirectoryName
        let file = try makeStaleFile("quarantine-probe.bin")
        let candidate = try makeCandidate(for: file, canonicalPath: quarantine + "/impostor")
        // 복구 대기 항목을 일반 후보로 삼으면 복구할 것이 사라진다.
        #expect(PermanentDeleter.delete(candidate) == .refused(.outsideProductionRoot))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("스캔 이후 내용이 바뀐 대상은 거부하고 그대로 둔다")
    func refusesWhenIdentityChanged() throws {
        // 회귀 방지 핵심. 스캔 결과의 URL을 그대로 지우면 그 사이 바뀐 파일을 날린다.
        let file = try makeStaleFile("mutated.bin")
        let candidate = try makeCandidate(for: file)

        try Data(repeating: 0x42, count: 128).write(to: file)

        #expect(PermanentDeleter.delete(candidate) == .refused(.identityChanged))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("이미 사라진 대상은 오류가 아니라 목표 달성으로 본다")
    func treatsMissingTargetAsDeleted() throws {
        // `/tmp`은 macOS 주기 작업이 상시 정리한다. 오류로 두면 목록에 남아
        // 누를 때마다 "errno 2"가 반복된다.
        let file = try makeStaleFile("vanished.bin")
        let candidate = try makeCandidate(for: file)
        try FileManager.default.removeItem(at: file)

        #expect(PermanentDeleter.delete(candidate) == .deleted)
    }

    @Test("이름만 같고 inode가 다른 파일은 지우지 않는다")
    func refusesWhenInodeReplaced() throws {
        // 회귀 방지 핵심. identity 비교를 mtime만으로 좁히면 이 대역이 통과한다.
        let target = try makeStaleFile("swap-target.bin", bytes: 32)
        let candidate = try makeCandidate(for: target)

        let decoy = try makeStaleFile("swap-decoy.bin", bytes: 32)
        // 타임스탬프를 같게 맞춘다. device/inode 비교만이 이걸 잡는다.
        var recorded = stat()
        #expect(lstat(target.path, &recorded) == 0)
        var times = [
            timeval(tv_sec: recorded.st_atimespec.tv_sec, tv_usec: 0),
            timeval(tv_sec: recorded.st_mtimespec.tv_sec, tv_usec: 0)
        ]
        #expect(utimes(decoy.path, &times) == 0)
        #expect(rename(decoy.path, target.path) == 0)

        #expect(PermanentDeleter.delete(candidate) == .refused(.identityChanged))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("열려 있는 파일은 거부한다")
    func refusesOpenFile() throws {
        let file = try makeStaleFile("held-open.bin")
        let candidate = try makeCandidate(for: file)

        let descriptor = open(file.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        #expect(PermanentDeleter.delete(candidate) == .refused(.inUse))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("안전하지 않은 하위 항목이 있는 디렉터리는 삭제를 시도하지 않는다")
    func refusesUnsafeTree() throws {
        try temp.makeFile("unsafe/inner.log", bytes: 8)
        let directory = temp.url.appendingPathComponent("unsafe")
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        for path in ["unsafe/inner.log", "unsafe/pipe", "unsafe"] {
            try setTimestamps(of: temp.url.appendingPathComponent(path), ageInDays: 10)
        }

        let candidate = try makeCandidate(for: directory)
        #expect(PermanentDeleter.delete(candidate) == .refused(.unsafeTree))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: fifo.path))
    }

    @Test("안전한 디렉터리는 트리째 사라진다")
    func deletesSafeDirectory() throws {
        try temp.makeFile("safe/nested/inner.log", bytes: 8)
        for path in ["safe/nested/inner.log", "safe/nested", "safe"] {
            try setTimestamps(of: temp.url.appendingPathComponent(path), ageInDays: 10)
        }

        let directory = temp.url.appendingPathComponent("safe")
        #expect(PermanentDeleter.delete(try makeCandidate(for: directory)) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("`:`가 든 두 canonical path는 서로 다른 ID다")
    func colonInPathDoesNotCollideIDs() throws {
        // 서로 다른 두 파일로 비교하면 inode가 달라 무조건 통과한다.
        // ID가 구분 문자로 이어붙인 문자열이었다면 `a:b` + `:c`와 `a:b:c` + `` 가
        // 같은 키가 된다. device/inode를 똑같이 두고 경로만 달리해야 그걸 잡는다.
        let source = try makeStaleFile("id-shared.bin")
        let first = try makeCandidate(for: source, canonicalPath: "/private/tmp/a:b")
        let second = try makeCandidate(for: source, canonicalPath: "/private/tmp/a:b:c")

        #expect(first.identity == second.identity)
        #expect(first.id != second.id)
        // 같은 경로 + 같은 identity는 같은 ID여야 한다.
        #expect(first.id == (try makeCandidate(for: source, canonicalPath: "/private/tmp/a:b")).id)
    }

    @Test("RENAME_EXCL은 목적지를 덮어쓰지 않는다")
    func renameExclusiveNeverClobbers() throws {
        // 격리 이동과 복원이 모두 이 원시 연산에 기대고 있다.
        let source = try temp.makeFile("excl-source.bin", bytes: 8)
        let occupied = try temp.makeFile("excl-target.bin", bytes: 16)

        let directory = open(temp.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0)
        defer { close(directory) }

        let clobber = renameatx_np(
            directory, "excl-source.bin", directory, "excl-target.bin", UInt32(RENAME_EXCL)
        )
        #expect(clobber == -1)
        #expect(errno == EEXIST)
        #expect(FileAttributes.size(of: occupied.path) == 16)
        #expect(FileManager.default.fileExists(atPath: source.path))

        let moved = renameatx_np(
            directory, "excl-source.bin", directory, "excl-free.bin", UInt32(RENAME_EXCL)
        )
        #expect(moved == 0)
    }
}

// MARK: - 외부 명령 계약

@Suite("외부 명령 계약")
struct ExternalCommandTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("비UTF8 바이트가 섞여도 출력을 통째로 버리지 않는다")
    func keepsOutputWithInvalidUTF8() {
        // `String(data:encoding:)`는 nil을 주고, 그러면 lsof 결과 전체가 사라져
        // 임시파일 탭이 영구 정지한다.
        let result = ShellRunner.run("/bin/dd", ["if=/dev/urandom", "bs=4096", "count=1"])
        #expect(result.succeeded)
        #expect(!result.output.isEmpty)
    }
}

// MARK: - 마운트 경계

/// 실제 볼륨을 붙여야 검증되는 가드. 디스크 이미지를 만들고 붙였다가 반드시 뗀다.
@Suite("마운트 경계", .serialized)
struct MountBoundaryTests {
    @Test("마운트 포인트는 후보가 되지 않고 삭제도 거부된다")
    func refusesMountPoint() throws {
        let root = try userTempRoot
        let name = "DiskTidyMount-\(UUID().uuidString)"
        let mountPoint = root + "/" + name
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: mountPoint) }

        let image = NSTemporaryDirectory() + "DiskTidyMountImage-\(UUID().uuidString)"
        #expect(ShellRunner.run("/usr/bin/hdiutil", [
            "create", "-size", "8m", "-fs", "APFS", "-volname", "DiskTidyMount", "-ov", image
        ]).succeeded)
        defer { try? FileManager.default.removeItem(atPath: image + ".dmg") }

        let attach = ShellRunner.run("/usr/bin/hdiutil", [
            "attach", image + ".dmg", "-mountpoint", mountPoint, "-nobrowse"
        ])
        #expect(attach.succeeded)
        let device = attach.output.split(separator: "\n").first?
            .split(separator: " ").first.map(String.init) ?? ""
        defer { ShellRunner.run("/usr/bin/hdiutil", ["detach", device, "-force"]) }

        // 볼륨을 **비워 둔다**. 내용이 있으면 하위 트리 검증이 device 불일치로 먼저 잡아
        // 스캔 단계의 경계 검사가 중복이 되고, 그 가드를 지워도 테스트가 통과한다.
        try setTimestamps(of: URL(fileURLWithPath: mountPoint), ageInDays: 10)

        var mountStatus = stat()
        var rootStatus = stat()
        #expect(lstat(mountPoint, &mountStatus) == 0)
        #expect(lstat(root, &rootStatus) == 0)
        // 전제가 성립하지 않으면 이 테스트는 아무것도 검증하지 못한다.
        #expect(mountStatus.st_dev != rootStatus.st_dev)
        #expect(mountStatus.st_uid == getuid())

        // 스캔에 올라오면 사용자가 마운트된 볼륨을 삭제 대상으로 보게 된다.
        #expect(!Set(try TempScanner.scan().map(\.name)).contains(name))

        // 후보를 손으로 만들어 넘겨도 부모와 device가 달라 거부해야 한다.
        let candidate = try makeCandidate(for: URL(fileURLWithPath: mountPoint))
        #expect(PermanentDeleter.delete(candidate) == .refused(.unsafeTree))
        // 마운트가 그대로 붙어 있어야 한다.
        var afterStatus = stat()
        #expect(lstat(mountPoint, &afterStatus) == 0)
        #expect(afterStatus.st_dev == mountStatus.st_dev)
    }
}

// MARK: - 테스트 픽스처 회수

@Suite("TempDirectory 잔여물 회수", .serialized)
struct FixtureSweepTests {
    @Test("1시간 지난 자기 픽스처를 걷고 최근 것은 남긴다")
    func sweepsOnlyStaleFixtures() throws {
        // `$TMPDIR`은 임시파일 탭의 실제 삭제 루트다. 잔여물을 두면 3일 뒤
        // 사용자 화면의 삭제 후보로 올라온다.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let stale = root.appendingPathComponent("DiskTidyTests-\(UUID().uuidString)")
        let fresh = root.appendingPathComponent("DiskTidyTests-\(UUID().uuidString)")
        for url in [stale, fresh] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { for url in [stale, fresh] { try? FileManager.default.removeItem(at: url) } }
        try setTimestamps(of: stale, ageInDays: 1.0 / 12)   // 2시간 전

        // 회수는 프로세스당 한 번만 돌므로 트리거가 아니라 로직을 직접 부른다.
        TempDirectory.sweepStaleFixtures()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // 같이 돌고 있는 다른 테스트의 픽스처를 지우면 안 된다.
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}

// MARK: - 격리 이동 구간의 경합

/// 이동이 끝난 뒤 identity를 다시 확인하기 전까지가 마지막 이름이 바뀔 수 있는 구간이다.
/// 실제 경합은 재현할 수 없으므로 그 지점에 훅을 걸어 결정적으로 만든다.
@Suite("격리 이동 경합")
struct StageRaceTests {
    private let temp: TempDirectory
    private let root: String
    private let quarantine: URL
    private let records: URL

    init() throws {
        temp = try TempDirectory()
        root = try userTempRoot
        quarantine = URL(fileURLWithPath: root + "/" + TempScanner.quarantineDirectoryName)
        records = quarantine.appendingPathComponent("journal")
        for directory in [quarantine, records] {
            #expect(mkdir(directory.path, 0o700) == 0 || errno == EEXIST)
        }
    }

    private func makeStaleFile(_ name: String, bytes: Int = 64) throws -> URL {
        let file = try temp.makeFile(name, bytes: bytes)
        try setTimestamps(of: file, ageInDays: 10)
        return file
    }

    private func stageURL(_ id: UUID) -> URL { quarantine.appendingPathComponent(id.uuidString) }
    private func recordURL(_ id: UUID) -> URL {
        records.appendingPathComponent("\(id.uuidString).json")
    }

    private func discard(_ id: UUID) {
        try? FileManager.default.removeItem(at: stageURL(id))
        try? FileManager.default.removeItem(at: recordURL(id))
    }

    @Test("stage 이름이 이미 있으면 기존 항목을 건드리지 않고 새 이름으로 재시도한다")
    func retriesOnStageNameCollision() throws {
        let taken = UUID()
        let fresh = UUID()
        defer { discard(taken); discard(fresh) }

        // 이미 격리에 들어 있는 다른 항목. RENAME_EXCL이 이걸 덮어쓰면 안 된다.
        try Data(repeating: 0x5A, count: 11).write(to: stageURL(taken))

        let file = try makeStaleFile("collide.bin")
        let vendor = IDVendor([taken, fresh])
        let outcome = PermanentDeleter.delete(
            try makeCandidate(for: file),
            hooks: PermanentDeleter.StageHooks(nextStageID: { vendor.next() })
        )

        #expect(outcome == .deleted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // 기존 격리 항목은 크기까지 그대로여야 한다.
        #expect(FileAttributes.size(of: stageURL(taken).path) == 11)
        // 버려진 준비 레코드가 남으면 안 된다.
        #expect(!FileManager.default.fileExists(atPath: recordURL(taken).path))
        #expect(!FileManager.default.fileExists(atPath: recordURL(fresh).path))
        #expect(vendor.consumed == 2)
    }

    @Test("이동 직후 대상이 바뀌면 새 항목을 지우지 않고 되돌린다")
    func refusesWhenStagedIdentityChanged() throws {
        // 회귀 방지 핵심. 여기서 그냥 지우면 남이 끼워 넣은 다른 파일을 삭제한다.
        let stageID = UUID()
        defer { discard(stageID) }
        let file = try makeStaleFile("swapped.bin", bytes: 32)
        let candidate = try makeCandidate(for: file)

        let outcome = PermanentDeleter.delete(candidate, hooks: PermanentDeleter.StageHooks(
            nextStageID: { stageID },
            afterStage: { staged in
                try? FileManager.default.removeItem(at: staged)
                FileManager.default.createFile(
                    atPath: staged.path, contents: Data(repeating: 0x7E, count: 9)
                )
            }
        ))

        #expect(outcome == .refused(.identityChanged))
        // 갈아치운 항목은 삭제되지 않고 원래 이름으로 되돌아와 있어야 한다.
        #expect(FileAttributes.size(of: file.path) == 9)
        #expect(!FileManager.default.fileExists(atPath: stageURL(stageID).path))
        #expect(!FileManager.default.fileExists(atPath: recordURL(stageID).path))
    }

    @Test("되돌릴 자리가 이미 채워졌으면 덮어쓰지 않고 격리에 남긴다")
    func keepsStageWhenSourceNameRefilled() throws {
        let stageID = UUID()
        defer { discard(stageID) }
        let file = try makeStaleFile("refilled.bin", bytes: 32)
        let candidate = try makeCandidate(for: file)

        let outcome = PermanentDeleter.delete(candidate, hooks: PermanentDeleter.StageHooks(
            nextStageID: { stageID },
            afterStage: { staged in
                try? FileManager.default.removeItem(at: staged)
                FileManager.default.createFile(atPath: staged.path, contents: Data([0x7E]))
                // 원래 이름도 그 사이에 다시 채워졌다.
                FileManager.default.createFile(
                    atPath: file.path, contents: Data(repeating: 0x33, count: 5)
                )
            }
        ))

        #expect(outcome == .refused(.quarantineRecoveryRequired))
        #expect(FileAttributes.size(of: file.path) == 5)          // 덮어쓰지 않았다
        #expect(FileManager.default.fileExists(atPath: stageURL(stageID).path))
        #expect(PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }

    @Test("이동 직후 stage가 사라져도 복구 목록에 올리고 나중에 걷을 수 있다")
    func surfacesAndClearsVanishedStage() throws {
        let stageID = UUID()
        defer { discard(stageID) }
        let file = try makeStaleFile("vanished-stage.bin", bytes: 32)
        let candidate = try makeCandidate(for: file)

        let outcome = PermanentDeleter.delete(candidate, hooks: PermanentDeleter.StageHooks(
            nextStageID: { stageID },
            afterStage: { staged in try? FileManager.default.removeItem(at: staged) }
        ))

        #expect(outcome == .refused(.quarantineRecoveryRequired))
        #expect(PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
        // stage도 원본도 없는 staged 레코드는 삭제가 끝난 상태다. 걷지 못하면 영구히 남는다.
        #expect(PermanentDeleter.restore(stageID) == .restored)
        #expect(!PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }
}

/// stage 이름을 정해진 순서로 내준다. 백그라운드에서 불릴 수 있어 락으로 보호한다.
private final class IDVendor: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [UUID]
    private var used = 0

    init(_ queue: [UUID]) { self.queue = queue }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        used += 1
        return queue.isEmpty ? UUID() : queue.removeFirst()
    }

    var consumed: Int {
        lock.lock()
        defer { lock.unlock() }
        return used
    }
}

// MARK: - 격리 복구

/// 격리 journal의 on-disk 계약을 직접 만들어 검증한다. 앱이 이동 도중에 죽은 상태를
/// 재현할 다른 방법이 없다. 테스트가 만든 UUID 항목만 넣고 빼서 실제 격리 상태는
/// 건드리지 않는다.
@Suite("격리 복구")
struct QuarantineRecoveryTests {
    private let temp: TempDirectory
    private let root: String
    private let quarantine: URL
    private let records: URL
    private let stageID = UUID()

    init() throws {
        temp = try TempDirectory()
        root = try userTempRoot
        quarantine = URL(fileURLWithPath: root + "/" + TempScanner.quarantineDirectoryName)
        records = quarantine.appendingPathComponent("journal")

        // 스위트 인스턴스가 테스트마다 하나씩 병렬로 만들어진다. 다른 인스턴스가 먼저
        // 만들었으면 EEXIST가 정상이다.
        for directory in [quarantine, records] {
            #expect(mkdir(directory.path, 0o700) == 0 || errno == EEXIST)
            #expect(chmod(directory.path, 0o700) == 0)
        }
    }

    /// 이 테스트가 넣은 항목만 회수한다.
    private func cleanUp() {
        try? FileManager.default.removeItem(at: stageURL)
        try? FileManager.default.removeItem(
            at: records.appendingPathComponent("\(stageID.uuidString).json")
        )
    }

    private var stageURL: URL { quarantine.appendingPathComponent(stageID.uuidString) }

    /// 실제 파일을 격리로 옮겨 staged 상태를 만든다.
    private func stage(_ source: URL) throws {
        try FileManager.default.moveItem(at: source, to: stageURL)
    }

    private func writeRecord(
        sourceParentRelative: String,
        sourceName: String,
        identity: FileIdentity,
        state: String = "staged"
    ) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        let record: [String: Any] = [
            "id": stageID.uuidString,
            "sourceParentRelative": sourceParentRelative,
            "sourceName": sourceName,
            "identity": encoded,
            "state": state
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: records.appendingPathComponent("\(stageID.uuidString).json")
        )
    }

    /// `$TMPDIR` 기준 상대 경로. journal이 저장하는 형식과 같다.
    private var fixtureRelativePath: String {
        let canonical = CanonicalPath.normalizingPrefix(temp.url.path)
        return String(canonical.dropFirst(root.count + 1))
    }

    @Test("staged 항목은 원본 경로와 함께 복구 목록에 뜬다")
    func listsStagedRecovery() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("staged.bin", bytes: 32)
        try stage(source)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: "staged.bin",
            identity: try identity(of: stageURL)
        )

        let recovery = PermanentDeleter.pendingRecoveries().first { $0.id == stageID }
        #expect(recovery != nil)
        #expect(recovery?.originalPath.hasSuffix("/staged.bin") == true)
        #expect(recovery?.quarantinedPath.path == stageURL.path)
    }

    @Test("원래 이름이 비어 있으면 복원한다")
    func restoresIntoFreeName() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("restore-me.bin", bytes: 32)
        try stage(source)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: "restore-me.bin",
            identity: try identity(of: stageURL)
        )

        #expect(PermanentDeleter.restore(stageID) == .restored)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: stageURL.path))
        #expect(!PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }

    @Test("원래 이름이 다시 채워졌으면 덮어쓰지 않고 격리 항목을 보존한다")
    func neverClobbersOnRestore() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("occupied.bin", bytes: 32)
        try stage(source)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: "occupied.bin",
            identity: try identity(of: stageURL)
        )
        // 그 사이 같은 이름으로 새 파일이 생겼다.
        try Data(repeating: 0x5A, count: 7).write(to: source)

        #expect(PermanentDeleter.restore(stageID) == .refused(.quarantineRecoveryRequired))
        #expect(FileAttributes.size(of: source.path) == 7)
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
        #expect(PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }

    @Test("stage identity가 journal과 다르면 복원하지 않는다")
    func refusesRestoreOnIdentityMismatch() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("mismatch.bin", bytes: 32)
        try stage(source)
        let recorded = try identity(of: stageURL)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: "mismatch.bin",
            identity: FileIdentity(
                device: recorded.device,
                inode: recorded.inode &+ 1,
                ownerUID: recorded.ownerUID,
                mode: recorded.mode,
                modifiedAt: recorded.modifiedAt,
                accessedAt: recorded.accessedAt
            )
        )

        #expect(PermanentDeleter.restore(stageID) == .refused(.identityChanged))
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("손상된 journal 레코드는 목록에만 올리고 지우지 않는다")
    func surfacesDamagedRecord() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("damaged.bin", bytes: 32)
        try stage(source)
        try Data("{ not json".utf8).write(
            to: records.appendingPathComponent("\(stageID.uuidString).json")
        )

        let recovery = PermanentDeleter.pendingRecoveries().first { $0.id == stageID }
        #expect(recovery != nil)
        #expect(recovery?.originalPath.isEmpty == true)
        #expect(PermanentDeleter.restore(stageID) == .refused(.quarantineRecoveryRequired))
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
    }

    @Test("레코드 없는 고아 stage도 목록에만 올린다")
    func surfacesOrphanStage() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("orphan.bin", bytes: 32)
        try stage(source)

        let recovery = PermanentDeleter.pendingRecoveries().first { $0.id == stageID }
        #expect(recovery != nil)
        #expect(recovery?.originalPath.isEmpty == true)
        #expect(PermanentDeleter.restore(stageID) == .refused(.quarantineRecoveryRequired))
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
    }

    @Test("루트 밖을 가리키는 레코드는 복원하지 않는다")
    func refusesPathEscapeInRecord() throws {
        defer { cleanUp() }
        // journal은 디스크의 파일이다. 손상·조작된 레코드가 임의 경로 쓰기가 되면 안 된다.
        // 목적지가 없는 경로(`../../../../Users/somebody`)를 쓰면 가드가 없어도 open이
        // 실패해 같은 결과가 나온다. **존재하고 쓸 수 있는** 상위 경로여야 관측된다.
        let escaped = URL(fileURLWithPath: root)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskTidyEscaped-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: escaped) }

        let source = try temp.makeFile(escaped.lastPathComponent, bytes: 32)
        try stage(source)
        try writeRecord(
            sourceParentRelative: "..",
            sourceName: escaped.lastPathComponent,
            identity: try identity(of: stageURL)
        )

        #expect(PermanentDeleter.restore(stageID) == .refused(.quarantineRecoveryRequired))
        // 루트 밖으로 파일이 나가면 안 된다.
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
    }

    @Test("절대 경로·구분자가 든 레코드도 복원하지 않는다")
    func refusesAbsoluteAndSeparatorInRecord() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("bad-record.bin", bytes: 32)
        try stage(source)
        try writeRecord(
            sourceParentRelative: "/etc",
            sourceName: "passwd",
            identity: try identity(of: stageURL)
        )

        #expect(PermanentDeleter.restore(stageID) == .refused(.quarantineRecoveryRequired))
        #expect(FileManager.default.fileExists(atPath: stageURL.path))
    }

    @Test("이동 전에 끊긴 준비 레코드는 원본이 제자리면 레코드만 정리한다")
    func clearsPreparedRecordWhenSourceIntact() throws {
        defer { cleanUp() }
        let source = try temp.makeFile("prepared.bin", bytes: 32)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: "prepared.bin",
            identity: try identity(of: source),
            state: "prepared"
        )

        #expect(PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
        #expect(PermanentDeleter.restore(stageID) == .restored)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }

    @Test("stage도 원본도 없는 레코드는 상태와 무관하게 걷힌다", arguments: ["prepared", "staged"])
    func clearsRecordWithoutStageOrSource(state: String) throws {
        defer { cleanUp() }
        // 조건을 달면 복원도 삭제도 안 되는 행이 영구히 남는다. 격리에 든 게 없으므로
        // 레코드를 지워도 파일은 사라지지 않는다.
        let source = try temp.makeFile("gone-\(state).bin", bytes: 32)
        let recorded = try identity(of: source)
        try FileManager.default.removeItem(at: source)
        try writeRecord(
            sourceParentRelative: fixtureRelativePath,
            sourceName: source.lastPathComponent,
            identity: recorded,
            state: state
        )

        #expect(PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
        #expect(PermanentDeleter.restore(stageID) == .restored)
        #expect(!PermanentDeleter.pendingRecoveries().contains { $0.id == stageID })
    }

    @Test("모르는 ID로는 아무것도 복원하지 않는다")
    func refusesUnknownRecoveryID() {
        #expect(PermanentDeleter.restore(UUID()) == .refused(.quarantineRecoveryRequired))
    }
}

// MARK: - 스캔 통합

@Suite("TempScanner 통합")
struct TempScannerIntegrationTests {
    @Test("음수 보존 기간은 스캔 전에 막는다")
    func rejectsNegativeMinimumAge() {
        #expect(throws: TempScanner.ScanError.invalidMinimumAge) {
            _ = try TempScanner.scan(minimumAgeDays: -1)
        }
    }

    @Test("고정 production root에서 규칙이 함께 걸린다")
    func appliesAllRulesOnRealRoots() throws {
        let root = URL(fileURLWithPath: try userTempRoot)
        let prefix = "DiskTidyScanFixture-\(UUID().uuidString)"

        let stale = root.appendingPathComponent("\(prefix)-stale")
        let fresh = root.appendingPathComponent("\(prefix)-fresh")
        let pipe = root.appendingPathComponent("\(prefix)-pipe")
        let held = root.appendingPathComponent("\(prefix)-held")
        defer {
            for url in [stale, fresh, pipe, held] { try? FileManager.default.removeItem(at: url) }
        }

        for url in [stale, fresh, held] {
            try Data(repeating: 0x41, count: 1024).write(to: url)
        }
        #expect(mkfifo(pipe.path, 0o600) == 0)
        for url in [stale, pipe, held] { try setTimestamps(of: url, ageInDays: 10) }

        let descriptor = open(held.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let names = Set(try TempScanner.scan().map(\.name))
        #expect(names.contains("\(prefix)-stale"))
        #expect(!names.contains("\(prefix)-fresh")) // 규칙 3
        #expect(!names.contains("\(prefix)-pipe"))  // 규칙 2
        #expect(!names.contains("\(prefix)-held"))  // 규칙 4
        #expect(!names.contains(TempScanner.quarantineDirectoryName))
    }

    @Test("디렉터리 후보의 하위 트리 검증이 실제 스캔에서 걸린다")
    func appliesTreeVerificationOnRealRoots() throws {
        // 이 배선이 없으면 스캔은 최상위 lstat만 보고 디렉터리를 통째로 후보에 올린다.
        let root = URL(fileURLWithPath: try userTempRoot)
        let prefix = "DiskTidyTreeFixture-\(UUID().uuidString)"
        let safe = root.appendingPathComponent("\(prefix)-dir-safe")
        let unsafe = root.appendingPathComponent("\(prefix)-dir-unsafe")
        defer {
            for url in [safe, unsafe] { try? FileManager.default.removeItem(at: url) }
        }

        for directory in [safe, unsafe] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 512)
                .write(to: directory.appendingPathComponent("inner.log"))
        }
        #expect(mkfifo(unsafe.appendingPathComponent("pipe").path, 0o600) == 0)

        // 부모를 나중에 손대야 자식 갱신이 부모 타임스탬프를 되돌리지 않는다.
        for url in [
            safe.appendingPathComponent("inner.log"), safe,
            unsafe.appendingPathComponent("inner.log"), unsafe.appendingPathComponent("pipe"), unsafe
        ] { try setTimestamps(of: url, ageInDays: 10) }

        let names = Set(try TempScanner.scan().map(\.name))
        #expect(names.contains("\(prefix)-dir-safe"))
        #expect(!names.contains("\(prefix)-dir-unsafe"))
    }
}

// MARK: - 격리 디렉터리 권한

/// 격리 디렉터리를 통째로 chmod하므로, 다른 스위트가 쓰는 `$TMPDIR` 쪽이 아니라
/// **`/private/tmp` 루트의 격리 디렉터리**만 건드린다. 두 루트는 격리 디렉터리가 서로 다르다.
@Suite("격리 디렉터리 권한", .serialized)
struct QuarantinePermissionTests {
    private let root = "/private/tmp"

    @Test("격리 디렉터리 권한이 0700이 아니면 삭제를 거부한다")
    func refusesWhenQuarantineIsTooOpen() throws {
        // 다른 프로세스가 stage 항목을 갈아치우는 것을 막는 유일한 통제다.
        let quarantine = root + "/" + TempScanner.quarantineDirectoryName
        let existed = FileManager.default.fileExists(atPath: quarantine)
        if !existed { #expect(mkdir(quarantine, 0o700) == 0) }
        #expect(chmod(quarantine, 0o777) == 0)
        defer {
            if existed { chmod(quarantine, 0o700) } else { try? FileManager.default.removeItem(atPath: quarantine) }
        }

        let file = URL(fileURLWithPath: root + "/DiskTidyPerm-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 32).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try setTimestamps(of: file, ageInDays: 10)

        #expect(
            PermanentDeleter.delete(try makeCandidate(for: file))
                == .refused(.quarantineUnavailable)
        )
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("격리 이름이 심볼릭 링크면 링크 대상의 권한을 건드리지 않는다")
    func neverChmodsThroughSymbolicLink() throws {
        // `/private/tmp`은 1777이라 타 UID가 lstat~mkdir 사이에 링크를 끼울 수 있다.
        // `chmod`는 링크를 따라가므로 우리 소유 임의 디렉터리가 0700이 된다.
        let quarantine = root + "/" + TempScanner.quarantineDirectoryName
        let existing = FileManager.default.fileExists(atPath: quarantine)
        if existing { try FileManager.default.removeItem(atPath: quarantine) }
        defer {
            try? FileManager.default.removeItem(atPath: quarantine)
            if existing { mkdir(quarantine, 0o700) }
        }

        let victim = URL(fileURLWithPath: root + "/DiskTidyVictim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: victim) }
        #expect(chmod(victim.path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(
            atPath: quarantine, withDestinationPath: victim.path
        )

        let file = URL(fileURLWithPath: root + "/DiskTidySym-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 32).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try setTimestamps(of: file, ageInDays: 10)

        #expect(
            PermanentDeleter.delete(try makeCandidate(for: file))
                == .refused(.quarantineUnavailable)
        )
        var victimStatus = stat()
        #expect(lstat(victim.path, &victimStatus) == 0)
        #expect(victimStatus.st_mode & 0o777 == 0o755)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("성공한 삭제는 journal에 임시 파일을 남기지 않는다")
    func leavesNoJournalTemporaries() throws {
        // 레코드를 제자리에서 자르지 않고 temp + rename으로 갈아 끼운다.
        let quarantine = root + "/" + TempScanner.quarantineDirectoryName
        let records = quarantine + "/journal"
        let existing = FileManager.default.fileExists(atPath: quarantine)
        defer { if !existing { try? FileManager.default.removeItem(atPath: quarantine) } }

        let file = URL(fileURLWithPath: root + "/DiskTidyTmpLeak-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 32).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try setTimestamps(of: file, ageInDays: 10)

        #expect(PermanentDeleter.delete(try makeCandidate(for: file)) == .deleted)

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: records)) ?? []
        #expect(leftovers.allSatisfy { !$0.hasSuffix(".tmp") })
        #expect(leftovers.isEmpty)
    }
}

// MARK: - ViewModel 동작

/// 스캔·삭제·복원의 상태 전이. 대역만 주입하므로 실제 파일시스템을 건드리지 않는다.
@Suite("TempCleanupViewModel 동작")
@MainActor
struct TempCleanupBehaviorTests {
    private func candidate(_ name: String, bytes: Int64 = 1024, selected: Bool = false) -> TempCandidate {
        TempCandidate(
            name: name,
            path: URL(fileURLWithPath: "/private/tmp/\(name)"),
            canonicalPath: "/private/tmp/\(name)",
            sizeBytes: bytes,
            modifiedDate: Date(timeIntervalSince1970: 0),
            identity: FileIdentity(
                device: 1, inode: UInt64(abs(name.hashValue)), ownerUID: getuid(), mode: 0o100_644,
                modifiedAt: FileTimestamp(seconds: 0, nanoseconds: 0),
                accessedAt: FileTimestamp(seconds: 0, nanoseconds: 0)
            ),
            isSelected: selected
        )
    }

    @Test("스캔 결과를 목록에 담고 진행 플래그를 되돌린다")
    func refreshFillsItems() async {
        let scanned = [candidate("a"), candidate("b")]
        let model = TempCleanupViewModel(scan: { .success(scanned) })

        model.refresh()

        #expect(await waitUntil { !model.isScanning })
        #expect(model.items.map(\.name) == ["a", "b"])
        #expect(model.errorMessage == nil)
    }

    @Test("복구 목록을 스캔보다 먼저 화면에 올린다")
    func recoveriesAppearBeforeScanFinishes() async {
        // 26GB 트리 스캔은 수십 초 걸린다. 대입까지 미루면 그동안 복구 섹션이 비어 보인다.
        let recovery = PermanentDeleter.QuarantineRecovery(
            id: UUID(), originalPath: "/private/tmp/a",
            quarantinedPath: URL(fileURLWithPath: "/private/tmp/.DiskTidyQuarantine/x")
        )
        // 스캔을 시간이 아니라 신호로 붙잡는다. 지연으로 어림잡으면 부하가 걸린 러너에서
        // 창을 놓쳐 흔들린다.
        let gate = ScanGate()
        let model = TempCleanupViewModel(
            scan: { gate.scan() },
            loadRecoveries: { [recovery] }
        )

        model.refresh()

        #expect(await waitUntil { !model.pendingRecoveries.isEmpty })
        // 스캔은 아직 게이트에 붙잡혀 있다. 복구 섹션이 그보다 먼저 떠야 한다.
        #expect(model.isScanning)
        gate.release()

        #expect(await waitUntil { !model.isScanning })
    }

    @Test("스캔 실패는 목록을 비우고 배너를 세운다")
    func scanFailureClearsItems() async {
        // 안전성을 더 이상 보증할 수 없는 항목에 삭제 버튼이 열리면 안 된다.
        let counter = CallCounter()
        let model = TempCleanupViewModel(scan: {
            counter.record()
            return .failure(.openPathQueryFailed(1))
        })
        model.items = [candidate("stale"), candidate("stale2")]

        model.refresh()

        #expect(await waitUntil { !model.isScanning })
        #expect(model.items.isEmpty)
        #expect(model.errorMessage?.contains("목록을 비웁니다") == true)
    }

    @Test("스캔 중 새로고침을 다시 눌러도 겹쳐 실행하지 않는다")
    func refreshIsReentrancyGuarded() async {
        let counter = CallCounter(delay: 0.2)
        let model = TempCleanupViewModel(scan: {
            counter.record()
            return .success([])
        })

        model.refresh()
        #expect(model.isScanning)
        model.refresh() // 무시돼야 한다

        #expect(await waitUntil { !model.isScanning })
        #expect(counter.count == 1)
    }

    @Test("삭제 시작 후 새로 체크한 항목은 목록에 남는다")
    func doesNotDropItemsSelectedMidDeletion() async {
        // 형제 뷰모델에서 실제로 났던 버그다. 현재 선택 상태로 목록을 지우면
        // 삭제되지도 않은 항목이 조용히 사라진다.
        let gate = DeleteGate()
        let model = TempCleanupViewModel(delete: { gate.delete($0) })
        model.items = [candidate("a", selected: true), candidate("b")]

        model.deleteSelected()
        #expect(await waitUntil { gate.deletedNames.count == 1 })
        model.items[1].isSelected = true
        gate.release()

        #expect(await waitUntil { !model.isDeleting })
        #expect(gate.deletedNames == ["a"])
        #expect(model.items.map(\.name) == ["b"])
    }

    @Test("격리에 남은 항목은 후보 목록에서 빠지고 복구 섹션으로 간다")
    func movesQuarantinedItemOutOfCandidates() async {
        let recovery = PermanentDeleter.QuarantineRecovery(
            id: UUID(), originalPath: "/private/tmp/a",
            quarantinedPath: URL(fileURLWithPath: "/private/tmp/.DiskTidyQuarantine/x")
        )
        let model = TempCleanupViewModel(
            delete: { _ in .refused(.quarantineRecoveryRequired) },
            loadRecoveries: { [recovery] }
        )
        model.items = [candidate("a", selected: true), candidate("b")]

        model.deleteSelected()

        #expect(await waitUntil { !model.isDeleting })
        // 후보로 남으면 다시 눌러도 원본이 없어 반복 실패한다.
        #expect(model.items.map(\.name) == ["b"])
        #expect(model.pendingRecoveries.count == 1)
        #expect(model.errorMessage?.contains("복구 목록") == true)
    }

    @Test("삭제 실패는 항목을 남기고 요약을 내지 않는다")
    func failedDeletionKeepsItem() async {
        let model = TempCleanupViewModel(delete: { _ in .refused(.inUse) })
        model.items = [candidate("a", selected: true)]

        model.deleteSelected()

        #expect(await waitUntil { !model.isDeleting })
        #expect(model.items.map(\.name) == ["a"])
        #expect(model.deletionSummary == nil)
        #expect(model.errorMessage?.contains("사용 중") == true)
    }

    @Test("복원 실패는 스캔 실패 배너를 지우지 않는다")
    func restoreKeepsScanFailureBanner() async {
        let model = TempCleanupViewModel(
            scan: { .failure(.malformedOpenPathOutput) },
            restoreRecovery: { _ in .restored }
        )
        model.refresh()
        #expect(await waitUntil { !model.isScanning })
        let banner = model.errorMessage
        #expect(banner != nil)

        model.restore(UUID())

        #expect(await waitUntil { !model.isDeleting })
        // 배너가 사라지면 목록이 빈 이유를 알 수 없게 된다.
        #expect(model.errorMessage == banner)
    }

    @Test("선택이 없으면 아무것도 지우지 않는다")
    func noSelectionIsNoOp() {
        let gate = DeleteGate()
        let model = TempCleanupViewModel(delete: { gate.delete($0) })
        model.items = [candidate("a")]

        model.deleteSelected()

        #expect(!model.isDeleting)
        #expect(gate.deletedNames.isEmpty)
        #expect(model.items.count == 1)
    }
}

/// 백그라운드 Task에서 불리므로 락으로 보호한다.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    func record() {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// 스캔을 신호가 올 때까지 붙잡는다.
private final class ScanGate: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)

    func scan() -> Result<[TempCandidate], TempScanner.ScanError> {
        gate.wait()
        return .success([])
    }

    func release() { gate.signal() }
}

/// 삭제 한 건을 신호가 올 때까지 붙잡는다. 시간으로 어림잡으면 느린 러너에서 흔들린다.
private final class DeleteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    func delete(_ candidate: TempCandidate) -> PermanentDeleter.Outcome {
        lock.lock()
        recorded.append(candidate.name)
        lock.unlock()
        gate.wait()
        return .deleted
    }

    func release() { gate.signal() }

    var deletedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - ViewModel 문구

@Suite("TempCleanupViewModel 문구")
struct TempCleanupMessageTests {
    @Test("전부 성공하면 오류 문구가 없다")
    func noMessageWhenAllDeleted() {
        #expect(TempCleanupViewModel.failureMessage([.deleted, .deleted]) == nil)
        #expect(TempCleanupViewModel.failureMessage([]) == nil)
    }

    @Test("실패 건수와 이유를 중복 없이 모은다")
    func aggregatesFailures() {
        let message = TempCleanupViewModel.failureMessage([
            .deleted, .refused(.inUse), .refused(.inUse), .failed(13)
        ])
        #expect(message?.contains("3개") == true)
        #expect(message?.contains("errno 13") == true)
        // 같은 이유가 두 번 나열되면 안 된다.
        #expect(message?.components(separatedBy: "사용 중").count == 2)
    }

    @Test("스캔 실패 문구는 목록을 비운다는 사실을 알린다")
    func scanFailureMentionsClearedList() {
        #expect(
            TempCleanupViewModel.scanFailureMessage(.openPathQueryFailed(1))
                .contains("목록을 비웁니다")
        )
        #expect(
            TempCleanupViewModel.scanFailureMessage(.inaccessibleRoot("/private/tmp"))
                .contains("/private/tmp")
        )
    }

    @Test("복원 성공은 문구가 없고 실패는 이유를 준다")
    func restoreMessages() {
        #expect(TempCleanupViewModel.restoreFailureMessage(.restored) == nil)
        #expect(
            TempCleanupViewModel.restoreFailureMessage(.refused(.identityChanged))?
                .contains("바뀜") == true
        )
        #expect(TempCleanupViewModel.restoreFailureMessage(.failed(5))?.contains("errno 5") == true)
    }

    @Test("요약은 회수량을 약속하지 않는다")
    func summaryDoesNotPromiseReclaim() {
        let summary = TempCleanupViewModel.summary(
            deletedCount: 3, deletedBytes: 1_048_576, availableBytes: 2_147_483_648
        )
        #expect(summary?.contains("경로 3개 삭제") == true)
        #expect(summary?.contains("현재 여유 용량") == true)
        #expect(summary?.contains("반영이 늦어질 수 있습니다") == true)
        // 아무것도 지우지 못했으면 요약을 내지 않는다.
        #expect(
            TempCleanupViewModel.summary(deletedCount: 0, deletedBytes: 0, availableBytes: 1) == nil
        )
    }
}
