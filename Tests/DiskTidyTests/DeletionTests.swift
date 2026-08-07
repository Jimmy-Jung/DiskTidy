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
        let trash = TrashRecorder(delay: 0.3)
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true), item("b")]

        viewModel.deleteSelected()
        try? await Task.sleep(for: .milliseconds(50))
        viewModel.items[1].isSelected = true

        #expect(await waitUntil { !viewModel.isDeleting })
        #expect(trash.trashedNames == ["a"])
        #expect(viewModel.items.map(\.name) == ["b"])
    }

    @Test("삭제 중 다시 누르면 무시한다")
    func deleteIsReentrancyGuarded() async {
        let trash = TrashRecorder(delay: 0.2)
        let viewModel = CleanableListViewModel(scan: { [] }, trash: { trash.trash($0) })
        viewModel.items = [item("a", selected: true)]

        viewModel.deleteSelected()
        #expect(viewModel.isDeleting)
        viewModel.deleteSelected()

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
