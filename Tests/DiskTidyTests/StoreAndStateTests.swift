import Foundation
import Testing

@testable import DiskTidy

// MARK: - RootFolderStore 영속성

/// 프로덕션 키(`ProjectCacheRoots` · `BigFileRoots`)를 건드리지 않도록
/// 테스트마다 고유 키를 쓰고 끝나면 지운다.
@Suite("RootFolderStore 영속성")
struct RootFolderStorePersistenceTests {
    private let temp: TempDirectory
    private let key: String

    init() throws {
        temp = try TempDirectory()
        key = "DiskTidyTests-\(UUID().uuidString)"
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("저장한 폴더를 그대로 읽어온다")
    func roundTripsRoots() throws {
        defer { cleanUp() }
        let first = try temp.makeDirectory("Projects")
        let second = try temp.makeDirectory("Work")

        RootFolderStore.save([first, second], key: key)

        #expect(RootFolderStore.load(key: key).map(\.path) == [first.path, second.path])
    }

    @Test("사라진 폴더는 걸러내고 걸러낸 결과를 다시 저장한다")
    func prunesMissingRootsAndPersists() throws {
        defer { cleanUp() }
        let alive = try temp.makeDirectory("Alive")
        let removed = try temp.makeDirectory("Removed")
        RootFolderStore.save([alive, removed], key: key)
        try FileManager.default.removeItem(at: removed)

        // 남겨두면 스캔이 조용히 0건을 내놓는다.
        #expect(RootFolderStore.load(key: key).map(\.path) == [alive.path])
        // 다음 실행에서 또 걸러내지 않도록 정리된 목록이 저장돼야 한다.
        #expect(UserDefaults.standard.stringArray(forKey: key) == [alive.path])
    }

    @Test("저장된 적 없는 키는 빈 배열을 준다")
    func unknownKeyGivesEmpty() {
        defer { cleanUp() }
        #expect(RootFolderStore.load(key: key).isEmpty)
    }
}

// MARK: - RootFolderStore 추가 거부 규칙

@Suite("RootFolderStore 추가 거부 규칙")
struct RootFolderRejectionExtraTests {
    @Test("시스템 폴더도 거부한다", arguments: ["/Library", "/private"])
    func rejectsSystemPaths(path: String) {
        #expect(RootFolderStore.rejectionReason(for: URL(fileURLWithPath: path), existing: []) == .tooBroad)
    }

    @Test("경로를 표준화한 뒤 판정한다")
    func standardizesBeforeJudging() {
        // "/Users/../Users"처럼 우회해서 금지 경로를 통과시키면 안 된다.
        let sneaky = URL(fileURLWithPath: "/Users/../Users")
        #expect(RootFolderStore.rejectionReason(for: sneaky, existing: []) == .tooBroad)
    }

    @Test("표기가 달라도 같은 폴더면 중복으로 본다")
    func detectsDuplicateAcrossNotations() {
        let existing = URL(fileURLWithPath: "/Users/dev/Projects")
        let same = URL(fileURLWithPath: "/Users/dev/Work/../Projects")
        #expect(RootFolderStore.rejectionReason(for: same, existing: [existing]) == .alreadyAdded)
    }

    @Test("금지 경로의 하위 폴더는 허용한다")
    func allowsChildrenOfForbiddenPaths() {
        let child = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects")
        #expect(RootFolderStore.rejectionReason(for: child, existing: []) == nil)
    }

    @Test("거부 사유마다 안내 문구가 다르다")
    func messagesDiffer() {
        #expect(RootFolderStore.RejectionReason.tooBroad.message.contains("범위가 너무 넓어"))
        #expect(RootFolderStore.RejectionReason.alreadyAdded.message.contains("이미 추가된"))
    }
}

// MARK: - RootFolderViewModel

@Suite("RootFolderViewModel")
@MainActor
struct RootFolderViewModelTests {
    private let temp: TempDirectory
    private let key: String

    init() throws {
        temp = try TempDirectory()
        key = "DiskTidyTests-\(UUID().uuidString)"
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("저장된 값이 없으면 기본 폴더를 채우고 저장한다")
    func seedsDefaultRoots() throws {
        defer { cleanUp() }
        let downloads = try temp.makeDirectory("Downloads")

        let viewModel = RootFolderViewModel(storeKey: key, defaultRoots: [downloads])

        #expect(viewModel.roots.map(\.path) == [downloads.path])
        #expect(UserDefaults.standard.stringArray(forKey: key) == [downloads.path])
    }

    @Test("저장된 값이 있으면 기본 폴더를 무시한다")
    func storedRootsWinOverDefaults() throws {
        defer { cleanUp() }
        let stored = try temp.makeDirectory("Stored")
        let fallback = try temp.makeDirectory("Fallback")
        RootFolderStore.save([stored], key: key)

        let viewModel = RootFolderViewModel(storeKey: key, defaultRoots: [fallback])

        #expect(viewModel.roots.map(\.path) == [stored.path])
    }

    @Test("폴더를 지우면 즉시 저장에 반영한다")
    func removeRootPersists() throws {
        defer { cleanUp() }
        let first = try temp.makeDirectory("First")
        let second = try temp.makeDirectory("Second")
        RootFolderStore.save([first, second], key: key)
        let viewModel = RootFolderViewModel(storeKey: key)

        viewModel.removeRoot(first)

        #expect(viewModel.roots.map(\.path) == [second.path])
        #expect(UserDefaults.standard.stringArray(forKey: key) == [second.path])
    }

    @Test("목록에 없는 폴더를 지워도 아무 일도 없다")
    func removingUnknownRootIsNoOp() throws {
        defer { cleanUp() }
        let root = try temp.makeDirectory("Only")
        RootFolderStore.save([root], key: key)
        let viewModel = RootFolderViewModel(storeKey: key)

        viewModel.removeRoot(URL(fileURLWithPath: "/nowhere"))

        #expect(viewModel.roots.map(\.path) == [root.path])
    }

    @Test("표기가 달라도 같은 폴더면 제거된다")
    func removeRootMatchesAcrossNotations() throws {
        defer { cleanUp() }
        let root = try temp.makeDirectory("Only")
        RootFolderStore.save([root], key: key)
        let viewModel = RootFolderViewModel(storeKey: key)

        // 저장에서 되살아난 URL은 끝 슬래시가 붙어 원본과 `==`로는 어긋난다.
        viewModel.removeRoot(root)

        #expect(viewModel.roots.isEmpty)
        #expect(UserDefaults.standard.stringArray(forKey: key) == [])
    }
}

// MARK: - 저장 공간

@Suite("저장 공간")
@MainActor
struct StorageTests {
    @Test("현재 볼륨 용량을 읽는다")
    func readsCurrentVolumeCapacity() throws {
        let snapshot = try #require(StorageInfo.current())
        #expect(snapshot.totalBytes > 0)
        #expect(snapshot.availableBytes >= 0)
        #expect((0 ... 1).contains(snapshot.usedFraction))
    }

    @Test("모니터는 생성 즉시 스냅샷을 갖는다")
    func monitorRefreshesOnInit() {
        let monitor = StorageMonitor(refreshInterval: 3600)
        #expect(monitor.snapshot != nil)
        #expect(monitor.percentUsedText.hasSuffix("%"))
    }

    @Test("스냅샷이 없으면 자리표시자를 보여준다")
    func placeholderWithoutSnapshot() {
        let monitor = StorageMonitor(refreshInterval: 3600)
        monitor.snapshot = nil
        #expect(monitor.percentUsedText == "…")

        monitor.refresh()
        #expect(monitor.snapshot != nil)
    }

    @Test("사용률을 정수 퍼센트로 표기한다")
    func formatsPercent() {
        let monitor = StorageMonitor(refreshInterval: 3600)
        monitor.snapshot = StorageSnapshot(totalBytes: 1000, availableBytes: 250)
        #expect(monitor.percentUsedText == "75%")
    }

    @Test("남은 용량이 전체보다 크면 사용량이 음수가 된다")
    func negativeUsageIsSurfaced() {
        // 볼륨 API가 "중요 용도 가용량"을 크게 잡으면 실제로 생길 수 있는 값이다.
        let snapshot = StorageSnapshot(totalBytes: 100, availableBytes: 150)
        #expect(snapshot.usedBytes == -50)
        #expect(snapshot.usedFraction < 0)
    }
}

// MARK: - 모델 표시 형식

@Suite("모델 표시 형식")
struct ModelFormattingTests {
    @Test("CleanableItem은 크기를 사람이 읽는 문자열로 만든다")
    func cleanableSizeString() {
        let item = CleanableItem(
            name: "cache", path: URL(fileURLWithPath: "/tmp/cache"), sizeBytes: 5 * 1024 * 1024
        )
        #expect(item.sizeString.contains("MB"))
    }

    @Test("SimulatorItem은 마지막 사용일을 yyyy-MM-dd로 만든다")
    func simulatorLastUsedString() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 7
        let date = Calendar.current.date(from: components)!
        let item = SimulatorItem(
            id: "UDID", name: "iPhone 17", runtime: "iOS 26.5", state: "Shutdown",
            sizeBytes: 1024, lastUsed: date
        )
        #expect(item.lastUsedString == "2026-08-07")
    }

    @Test("네비게이션 상태는 첫 탭에서 시작한다")
    func navigationStartsAtFirstTab() {
        #expect(AppNavigationState().selectedTab == 0)
    }
}
