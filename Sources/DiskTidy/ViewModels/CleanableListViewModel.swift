import Foundation

/// 스캔 → 선택 → 휴지통 이동 흐름은 모든 캐시 탭이 동일하다.
/// 탭마다 ViewModel을 복제하는 대신 스캐너만 주입해서 하나로 쓴다.
@MainActor
final class CleanableListViewModel: ObservableObject {
    @Published var items: [CleanableItem] = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var errorMessage: String?

    /// 사용자가 고른 스캔 루트. 루트가 필요 없는 스캐너(캐시·Xcode 등)는 비워 둔다.
    /// 루트 기반 탭은 `RootFolderViewModel.roots` 변화를 여기에 반영한다.
    @Published var roots: [URL] = []

    /// 루트가 필수인 스캐너인지. true면 루트가 비었을 때 스캔을 건너뛴다.
    private let requiresRoots: Bool

    /// 백그라운드에서 실행되므로 Sendable 클로저여야 한다.
    private let scan: @Sendable ([URL]) -> [CleanableItem]

    /// 항목 본체 외에 함께 지워야 하는 부수 파일 (예: AVD의 `<name>.ini` 포인터).
    private let companionPaths: @Sendable (CleanableItem) -> [URL]

    /// 실제 삭제 수단. 테스트가 사용자의 휴지통을 건드리지 않도록 주입 가능하게 둔다.
    private let trash: @Sendable (URL) -> Bool

    init(
        scan: @escaping @Sendable () -> [CleanableItem],
        companionPaths: @escaping @Sendable (CleanableItem) -> [URL] = { _ in [] },
        trash: @escaping @Sendable (URL) -> Bool = { TrashService.trash($0) }
    ) {
        self.scan = { _ in scan() }
        self.companionPaths = companionPaths
        self.trash = trash
        requiresRoots = false
    }

    init(
        rootScan: @escaping @Sendable ([URL]) -> [CleanableItem],
        companionPaths: @escaping @Sendable (CleanableItem) -> [URL] = { _ in [] },
        trash: @escaping @Sendable (URL) -> Bool = { TrashService.trash($0) }
    ) {
        scan = rootScan
        self.companionPaths = companionPaths
        self.trash = trash
        requiresRoots = true
    }

    var selectedItems: [CleanableItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func refresh() {
        // 재진입 가드 없으면 새로고침 연타 시 스캔이 겹치고,
        // 늦게 끝난 오래된 결과가 최신 결과를 덮어쓴다.
        guard !isScanning else { return }
        errorMessage = nil

        if requiresRoots && roots.isEmpty {
            items = []
            return
        }

        isScanning = true
        let scan = self.scan
        let roots = self.roots
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { scan(roots) }.value
            self.items = scanned
            self.isScanning = false
        }
    }

    func deleteSelected() {
        guard !isDeleting else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        isDeleting = true
        errorMessage = nil

        let companionPaths = self.companionPaths
        let trash = self.trash
        Task {
            // 수 GB 디렉터리를 메인 스레드에서 지우면 UI가 멈춘다.
            let failedIDs = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
                var failed: Set<UUID> = []
                for item in targets {
                    guard trash(item.path) else {
                        failed.insert(item.id)
                        continue
                    }
                    // 부수 파일(AVD의 .ini 등)은 본체가 이미 지워진 뒤라 실패해도
                    // 용량에는 영향이 없다. TrashService가 로그를 남기므로 여기선 넘긴다.
                    for companion in companionPaths(item)
                        where FileManager.default.fileExists(atPath: companion.path) {
                        _ = trash(companion)
                    }
                }
                return failed
            }.value

            // 삭제 중에도 체크박스는 열려 있다. 현재 선택 상태로 지우면 삭제가 시작된 뒤
            // 새로 체크된 항목이 휴지통에 가지도 않은 채 목록에서만 사라진다.
            // 반드시 시작 시점에 스냅샷한 대상 ID로만 제거한다.
            let deletedIDs = Set(targets.map(\.id)).subtracting(failedIDs)
            self.items.removeAll { deletedIDs.contains($0.id) }
            self.isDeleting = false
            self.errorMessage = Self.failureMessage(failedCount: failedIDs.count)
        }
    }

    func selectAll(_ isSelected: Bool) {
        for index in items.indices { items[index].isSelected = isSelected }
    }

    nonisolated static func failureMessage(failedCount: Int) -> String? {
        guard failedCount > 0 else { return nil }
        return "\(failedCount)개 항목을 휴지통으로 옮기지 못했습니다 (권한 부족 또는 사용 중인 파일). 자세한 내용은 Console.app에서 DiskTidy 로그를 확인하세요."
    }
}
