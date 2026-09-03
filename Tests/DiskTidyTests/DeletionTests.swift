import Foundation
import Testing

@testable import DiskTidy

// MARK: - TrashService

/// 실제 휴지통을 쓰는 유일한 스위트. 고유 이름 파일만 만들고 곧바로 회수한다.
@Suite("TrashService")
struct TrashServiceTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("파일을 휴지통으로 옮기고 원래 경로를 비운다")
    func trashesFile() throws {
        let name = "DiskTidyTrashTest-\(UUID().uuidString).bin"
        let file = try temp.makeFile(name, bytes: 32)

        #expect(TrashService.trash(file))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // 사용자의 휴지통에 잔여물을 남기지 않는다.
        let trashed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/\(name)")
        try? FileManager.default.removeItem(at: trashed)
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test("없는 경로는 false를 준다")
    func missingPathFails() {
        #expect(!TrashService.trash(temp.url.appendingPathComponent("nope")))
    }
}

// MARK: - CleanableListViewModel 스캔

@Suite("CleanableListViewModel 스캔")
@MainActor
struct CleanableListScanTests {
    private func item(_ name: String, bytes: Int64 = 1024, selected: Bool = false) -> CleanableItem {
        CleanableItem(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            sizeBytes: bytes,
            isSelected: selected
        )
    }

    @Test("스캔 결과를 목록에 담고 진행 플래그를 되돌린다")
    func refreshFillsItems() async {
        let recorder = ScanRecorder(result: [item("a"), item("b")])
        let viewModel = CleanableListViewModel(scan: { recorder.scan([]) })

        viewModel.refresh()

        #expect(await waitUntil { !viewModel.isScanning })
        #expect(viewModel.items.map(\.name) == ["a", "b"])
        #expect(recorder.callCount == 1)
    }

    @Test("스캔 중 새로고침을 다시 눌러도 겹쳐 실행하지 않는다")
    func refreshIsReentrancyGuarded() async {
        let recorder = ScanRecorder(result: [item("a")], delay: 0.2)
        let viewModel = CleanableListViewModel(scan: { recorder.scan([]) })

        viewModel.refresh()
        #expect(viewModel.isScanning)
        viewModel.refresh() // 무시돼야 한다

        #expect(await waitUntil { !viewModel.isScanning })
        #expect(recorder.callCount == 1)
    }

    @Test("루트가 필요한 스캐너는 루트가 비면 스캔하지 않는다")
    func skipsScanWhenRootsRequiredButEmpty() {
        let recorder = ScanRecorder(result: [item("a")])
        let viewModel = CleanableListViewModel(rootScan: { recorder.scan($0) })
        viewModel.items = [item("stale")]

        viewModel.refresh()

        #expect(viewModel.items.isEmpty)
        #expect(!viewModel.isScanning)
        #expect(recorder.callCount == 0)
    }

    @Test("설정한 루트를 스캐너에 그대로 넘긴다")
    func passesRootsToScanner() async {
        let recorder = ScanRecorder(result: [item("a")])
        let viewModel = CleanableListViewModel(rootScan: { recorder.scan($0) })
        let root = URL(fileURLWithPath: "/Users/dev/Projects")
        viewModel.roots = [root]

        viewModel.refresh()

        #expect(await waitUntil { !viewModel.isScanning })
        #expect(recorder.lastRoots == [root])
    }

    @Test("루트가 필요한데 비어 있으면 폴더 추가를 안내한다")
    func emptyStateAsksForRootWhenRequired() {
        let viewModel = CleanableListViewModel(rootScan: { _ in [] })

        #expect(viewModel.emptyStateMessage.contains("폴더 추가"))

        viewModel.roots = [URL(fileURLWithPath: "/tmp")]
        #expect(viewModel.emptyStateMessage == "항목 없음")
    }

    @Test("루트가 필요 없는 스캐너는 항목 없음으로 끝난다")
    func emptyStateStaysPlainWithoutRoots() {
        #expect(CleanableListViewModel(scan: { [] }).emptyStateMessage == "항목 없음")
    }

    @Test("읽을 수 없는 루트만 골라내고 배너 문구를 만든다")
    func detectsUnreadableRoots() throws {
        let temp = try TempDirectory()
        let readable = try temp.makeDirectory("Readable")
        let denied = try temp.makeDirectory("Denied")
        let missing = temp.url.appendingPathComponent("Missing")
        // 권한을 되돌려 놓지 않으면 임시 디렉터리 정리가 실패한다.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: denied.path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let unreadable = CleanableListViewModel.unreadableRoots([readable, denied, missing])

        // 없는 폴더는 권한 문제가 아니다 — `RootFolderStore.load`가 이미 걸러낸다.
        #expect(unreadable == [denied])
        let message = try #require(CleanableListViewModel.unreadableRootsMessage(unreadable))
        #expect(message.contains("Denied"))
        #expect(CleanableListViewModel.unreadableRootsMessage([]) == nil)
    }

    @Test("선택 합계와 전체 선택·해제가 맞물린다")
    func selectionAggregates() {
        let viewModel = CleanableListViewModel(scan: { [] })
        viewModel.items = [item("a", bytes: 100), item("b", bytes: 250)]

        #expect(viewModel.selectedItems.isEmpty)
        #expect(viewModel.selectedBytes == 0)

        viewModel.selectAll(true)
        #expect(viewModel.selectedItems.count == 2)
        #expect(viewModel.selectedBytes == 350)

        viewModel.selectAll(false)
        #expect(viewModel.selectedBytes == 0)
    }

    @Test("ids를 주면 그 항목만 전체 선택한다 — 검색으로 걸러 본 상태의 계약")
    func selectAllHonoursIDScope() {
        let viewModel = CleanableListViewModel(scan: { [] })
        viewModel.items = [item("a", bytes: 100), item("b", bytes: 250)]
        let visible = Set([viewModel.items[0].id])

        viewModel.selectAll(true, ids: visible)
        #expect(viewModel.selectedItems.map(\.name) == ["a"])

        // 해제도 같은 범위만 건드린다. 보이지 않는 항목의 선택은 그대로 남는다.
        viewModel.selectAll(true)
        viewModel.selectAll(false, ids: visible)
        #expect(viewModel.selectedItems.map(\.name) == ["b"])
    }
}

// MARK: - CleanableListViewModel 삭제

@Suite("CleanableListViewModel 삭제")
@MainActor
struct CleanableListDeletionTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    private func item(_ name: String, selected: Bool = false, path: URL? = nil) -> CleanableItem {
        CleanableItem(
            name: name,
            path: path ?? URL(fileURLWithPath: "/tmp/\(name)"),
            sizeBytes: 1024,
            isSelected: selected
        )
    }

    @Test("선택한 항목만 휴지통으로 보내고 목록에서 뺀다")
    func deletesOnlySelected() async {
        let trash = TrashRecorder()
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true), item("b"), item("c", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["a", "c"])
        #expect(viewModel.items.map(\.name) == ["b"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("취소하면 시작하지 않은 항목은 그대로 두고 진행률을 지운다")
    func cancelSkipsRemainingItems() async {
        let trash = TrashRecorder()
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [
            item("a", selected: true), item("b", selected: true), item("c", selected: true),
        ]

        viewModel.deleteSelected()
        // 같은 메인 액터 턴에서 취소한다. 삭제 Task의 본문은 이 턴이 끝나야 시작하므로
        // 첫 항목조차 손대기 전에 취소가 확정된다 — 시간에 기대지 않는 유일한 지점이다.
        viewModel.cancelDeletion()

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames.isEmpty)
        #expect(viewModel.items.map(\.name) == ["a", "b", "c"])
        #expect(viewModel.deletionProgress == nil)
        #expect(viewModel.errorMessage?.contains("취소") == true)
    }

    @Test("휴지통 이동에 실패한 항목은 목록에 남기고 알린다")
    func keepsFailedItemsAndReports() async {
        let trash = TrashRecorder(failingNames: ["b"])
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true), item("b", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isDeleting })
        // 실패를 무시하면 용량은 그대로인데 정리된 것처럼 보인다.
        #expect(viewModel.items.map(\.name) == ["b"])
        #expect(viewModel.errorMessage?.contains("1개") == true)
    }

    @Test("존재하는 부수 파일만 함께 지운다")
    func trashesExistingCompanionsOnly() async throws {
        let present = try temp.makeFile("Pixel_9.ini", bytes: 16)
        let absent = temp.url.appendingPathComponent("Pixel_8.ini")

        let trash = TrashRecorder()
        let viewModel = CleanableListViewModel(
            scan: { [] },
            companionPaths: { $0.name == "Pixel_9" ? [present] : [absent] },
            trash: { trash.trash($0) }
        )
        viewModel.items = [item("Pixel_9", selected: true), item("Pixel_8", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["Pixel_9", "Pixel_9.ini", "Pixel_8"])
    }

    @Test("본체 삭제에 실패하면 부수 파일도 건드리지 않는다")
    func skipsCompanionWhenPrimaryFails() async throws {
        let companion = try temp.makeFile("Pixel_9.ini", bytes: 16)
        let trash = TrashRecorder(failingNames: ["Pixel_9"])
        let viewModel = CleanableListViewModel(
            scan: { [] },
            companionPaths: { _ in [companion] },
            trash: { trash.trash($0) }
        )
        viewModel.items = [item("Pixel_9", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["Pixel_9"])
    }

    @Test("삭제 시작 후 새로 체크한 항목은 목록에 남는다")
    func doesNotDropItemsSelectedMidDeletion() async {
        // 삭제 중에도 체크박스는 열려 있다. 현재 선택 상태로 목록을 지우면
        // 휴지통에 가지도 않은 항목이 조용히 사라진다.
        let trash = TrashRecorder(gated: true)
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true), item("b")]

        viewModel.deleteSelected()
        // 첫 삭제가 실제로 시작될 때까지 붙잡는다. 시간으로 어림잡으면
        // 느린 러너에서 삭제가 먼저 끝나 아래 인덱스가 범위를 벗어난다.
        #expect(await waitUntil { trash.trashedNames.count == 1 })
        viewModel.items[1].isSelected = true
        trash.release()

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["a"])
        #expect(viewModel.items.map(\.name) == ["b"])
    }

    @Test("삭제 중 다시 누르면 무시한다")
    func deleteIsReentrancyGuarded() async {
        let trash = TrashRecorder(gated: true)
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true)]

        viewModel.deleteSelected()
        #expect(viewModel.isDeleting)
        viewModel.deleteSelected() // 무시돼야 한다

        // 재진입이 뚫리면 두 번째 삭제가 게이트에 걸려 영영 끝나지 않는다.
        trash.release()
        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["a"])
    }

    @Test("선택이 없으면 아무것도 지우지 않는다")
    func noSelectionIsNoOp() {
        let trash = TrashRecorder()
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a")]

        viewModel.deleteSelected()

        #expect(!viewModel.isDeleting)
        #expect(trash.trashedPaths.isEmpty)
        #expect(viewModel.items.count == 1)
    }
}
