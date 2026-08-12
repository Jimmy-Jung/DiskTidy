import Foundation

@testable import DiskTidy

// MARK: - 임시 디렉터리 픽스처

/// 스캐너는 실제 파일시스템을 훑으므로 픽스처도 진짜 디렉터리여야 한다.
/// 스위트 인스턴스가 사라질 때 통째로 지워 테스트 간 잔여물을 남기지 않는다.
final class TempDirectory {
    private static let namePrefix = "DiskTidyTests-"

    let url: URL

    /// 회수는 프로세스당 한 번이면 충분하다. 인스턴스마다 돌리면 잔여물이 많이 쌓였을 때
    /// (변이 검사처럼 테스트를 수십 번 돌린 뒤) 첫 생성이 수 초를 먹고,
    /// 대기 시간이 있는 테스트가 그 때문에 흔들린다.
    private static let sweepOnce: Void = sweepStaleFixtures()

    init() throws {
        _ = Self.sweepOnce
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(Self.namePrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `deinit`은 병렬 스위트에서 도는 것이 보장되지 않아 실행마다 픽스처가 쌓인다.
    /// 그냥 두면 `$TMPDIR`은 임시파일 탭의 실제 삭제 루트라, 3일 뒤 이 잔여물이
    /// 사용자 화면의 삭제 후보로 올라온다. 시작할 때 자기 것만 걷는다.
    static func sweepStaleFixtures() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let cutoff = Date().addingTimeInterval(-3600)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(namePrefix) {
            let stale = root.appendingPathComponent(name)
            let modified = (try? stale.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // 같이 돌고 있는 다른 테스트의 픽스처를 지우면 안 된다. 1시간 여유를 둔다.
            if modified < cutoff { try? FileManager.default.removeItem(at: stale) }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int = 0) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }

    /// 링크 순환에 빠지는지 확인할 때 쓴다.
    func makeSymbolicLink(_ relativePath: String, to destination: URL) throws {
        let link = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    func setModificationDate(_ date: Date, of target: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: target.path
        )
    }
}

// MARK: - 비동기 대기

/// `@MainActor` ViewModel이 내부 `Task`를 끝낼 때까지 기다린다.
/// 조건이 참이 되면 true, 제한 시간을 넘기면 false.
///
/// 상한이 넉넉한 이유: CI 러너가 개발 머신보다 훨씬 느리다. 같은 실행에서
/// `ShellRunner` 테스트가 로컬 3초 대 CI 24초였고, 10초로는 스캔·삭제를 기다리는
/// 테스트 16개가 한꺼번에 시간에 걸려 넘어졌다(실측). 조건이 참이 되면 즉시
/// 반환하므로 통과하는 실행의 소요 시간은 상한과 무관하다 — 늘려도 느려지지 않는다.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(60),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

// MARK: - 주입용 테스트 대역

/// 스캔 호출을 기록하는 대역. 백그라운드 Task에서 불리므로 락으로 보호한다.
final class ScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRoots: [[URL]] = []

    private let result: [CleanableItem]
    private let delay: TimeInterval

    init(result: [CleanableItem] = [], delay: TimeInterval = 0) {
        self.result = result
        self.delay = delay
    }

    func scan(_ roots: [URL]) -> [CleanableItem] {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        recordedRoots.append(roots)
        lock.unlock()
        return result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRoots.count
    }

    var lastRoots: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRoots.last ?? []
    }
}

/// 실제 휴지통 대신 호출만 기록하는 대역. `failingNames`에 든 파일명은 실패로 돌려준다.
final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    private let failingNames: Set<String>

    /// `gated: true`면 각 호출이 `release()`가 올 때까지 반환하지 않는다.
    /// "삭제 진행 중" 상태를 시간이 아니라 신호로 붙잡아 느린 CI에서도 흔들리지 않는다.
    private let gate: DispatchSemaphore?

    init(failingNames: Set<String> = [], gated: Bool = false) {
        self.failingNames = failingNames
        gate = gated ? DispatchSemaphore(value: 0) : nil
    }

    func trash(_ url: URL) -> Bool {
        lock.lock()
        recorded.append(url)
        lock.unlock()
        gate?.wait()
        return !failingNames.contains(url.lastPathComponent)
    }

    /// 붙잡아 둔 삭제 한 건을 재개시킨다.
    func release() { gate?.signal() }

    var trashedPaths: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var trashedNames: [String] { trashedPaths.map(\.lastPathComponent) }
}

/// simctl 대역. UDID별 성공/실패를 정하고 호출을 기록한다.
final class SimctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    private let failingUDIDs: Set<String>

    init(failingUDIDs: Set<String> = []) {
        self.failingUDIDs = failingUDIDs
    }

    func perform(_ udid: String) -> Bool {
        lock.lock()
        recorded.append(udid)
        lock.unlock()
        return !failingUDIDs.contains(udid)
    }

    var calledUDIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
