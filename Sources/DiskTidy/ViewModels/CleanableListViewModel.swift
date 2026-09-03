import Foundation

/// 스캔 → 선택 → 휴지통 이동 흐름은 모든 캐시 탭이 동일하다.
/// 탭마다 ViewModel을 복제하는 대신 스캐너만 주입해서 하나로 쓴다.
@MainActor
final class CleanableListViewModel: ObservableObject {
    @Published var items: [CleanableItem] = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var errorMessage: String?

    /// 삭제 진행률. 수 GB 디렉터리는 한 건에 몇 초씩 걸려 진행 표시가 없으면 멈춘 것처럼 보인다.
    @Published private(set) var deletionProgress: DeletionProgress?

    struct DeletionProgress: Equatable {
        var done: Int
        var total: Int
    }

    /// 진행 중인 삭제. 취소는 **아직 시작하지 않은 항목**만 건너뛴다 — 이미 휴지통으로 간 항목은
    /// 그대로 남는다(사용자가 휴지통에서 되돌릴 수 있다).
    private var deletionTask: Task<Void, Never>?

    /// 사용자가 고른 스캔 루트. 루트가 필요 없는 스캐너(캐시·Xcode 등)는 비워 둔다.
    /// 루트 기반 탭은 `RootFolderViewModel.roots` 변화를 여기에 반영한다.
    @Published var roots: [URL] = []

    /// 루트가 필수인 스캐너인지. true면 루트가 비었을 때 스캔을 건너뛴다.
    let requiresRoots: Bool

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

    /// 목록이 빈 이유를 갈라 말한다. 루트를 아직 안 고른 것과 스캔 결과가 0건인 것은
    /// 사용자가 할 일이 다르다. 둘 다 "항목 없음"으로 두면 폴더를 추가해야 하는 줄 모른다.
    var emptyStateMessage: String {
        requiresRoots && roots.isEmpty
            ? "스캔할 폴더가 없습니다. 위 ‘폴더 추가’로 프로젝트가 모여 있는 폴더를 선택하세요."
            : "항목 없음"
    }

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
            let scanned = await Task.detached(priority: .userInitiated) {
                (items: scan(roots), unreadableRoots: Self.unreadableRoots(roots))
            }.value
            self.items = scanned.items
            self.errorMessage = Self.unreadableRootsMessage(scanned.unreadableRoots)
            self.isScanning = false
        }
    }

    /// 존재하는데 목록을 읽을 수 없는 루트. 대개 `~/Documents`·`~/Desktop`처럼 macOS가
    /// 보호하는 위치에 접근 권한이 없는 경우다.
    ///
    /// 스캐너는 디렉터리 읽기 실패를 조용히 넘긴다(권한 없는 하위 폴더 하나로 전체 스캔을
    /// 멈출 수는 없다). 그래서 권한 거부가 "캐시 없음"과 화면상 구분되지 않았다. 루트만은
    /// 따로 확인해 배너로 올린다 — 루트를 못 읽으면 결과는 언제나 0건이다.
    nonisolated static func unreadableRoots(_ roots: [URL]) -> [URL] {
        let manager = FileManager.default
        return roots.filter { root in
            manager.fileExists(atPath: root.path)
                && (try? manager.contentsOfDirectory(atPath: root.path)) == nil
        }
    }

    nonisolated static func unreadableRootsMessage(_ roots: [URL]) -> String? {
        guard !roots.isEmpty else { return nil }
        let names = roots.map(\.lastPathComponent).joined(separator: ", ")
        return "\(names) 폴더를 읽을 권한이 없어 결과가 비어 있습니다. "
            + "시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더에서 DiskTidy의 접근을 허용하세요. "
            + "설정 탭의 ‘파일 접근 권한’에서 전체 디스크 접근을 켜면 폴더마다 허용할 필요가 없습니다."
    }

    func deleteSelected() {
        guard !isDeleting else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        isDeleting = true
        errorMessage = nil
        deletionProgress = DeletionProgress(done: 0, total: targets.count)

        let companionPaths = self.companionPaths
        let trash = self.trash
        deletionTask = Task {
            var failedIDs: Set<UUID> = []
            var deletedIDs: Set<UUID> = []

            for item in targets {
                // 취소는 항목 사이에서만 본다. 한 항목의 휴지통 이동은 쪼갤 수 없다.
                if Task.isCancelled { break }
                // 수 GB 디렉터리를 메인 스레드에서 지우면 UI가 멈춘다.
                let moved = await Task.detached(priority: .userInitiated) { () -> Bool in
                    guard trash(item.path) else { return false }
                    // 부수 파일(AVD의 .ini 등)은 본체가 이미 지워진 뒤라 실패해도 용량에는
                    // 영향이 없다. TrashService가 로그를 남기므로 여기선 넘긴다.
                    for companion in companionPaths(item)
                        where FileManager.default.fileExists(atPath: companion.path) {
                        _ = trash(companion)
                    }
                    return true
                }.value

                if moved { deletedIDs.insert(item.id) } else { failedIDs.insert(item.id) }
                self.deletionProgress = DeletionProgress(
                    done: deletedIDs.count + failedIDs.count, total: targets.count
                )
            }

            // 삭제 중에도 체크박스는 열려 있다. 현재 선택 상태로 지우면 삭제가 시작된 뒤
            // 새로 체크된 항목이 휴지통에 가지도 않은 채 목록에서만 사라진다.
            // 반드시 실제로 옮긴 ID로만 제거한다.
            self.items.removeAll { deletedIDs.contains($0.id) }
            let skipped = targets.count - deletedIDs.count - failedIDs.count
            self.errorMessage = Self.deletionMessage(
                failedCount: failedIDs.count, skippedCount: skipped
            )
            self.deletionProgress = nil
            self.isDeleting = false
            self.deletionTask = nil
        }
    }

    /// 남은 항목의 삭제를 그만둔다. 이미 옮긴 항목은 되돌리지 않는다.
    func cancelDeletion() {
        deletionTask?.cancel()
    }

    /// `ids`를 주면 그 항목만 바꾼다. 검색으로 걸러 본 상태에서 머리글 체크박스를 누르면
    /// 보이지 않는 항목까지 선택되면 안 된다.
    func selectAll(_ isSelected: Bool, ids: Set<UUID>? = nil) {
        for index in items.indices where ids?.contains(items[index].id) ?? true {
            items[index].isSelected = isSelected
        }
    }

    nonisolated static func failureMessage(failedCount: Int) -> String? {
        guard failedCount > 0 else { return nil }
        return "\(failedCount)개 항목을 휴지통으로 옮기지 못했습니다 (권한 부족 또는 사용 중인 파일). 자세한 내용은 Console.app에서 DiskTidy 로그를 확인하세요."
    }

    /// 실패와 취소를 한 배너에 담는다. 취소는 오류가 아니므로 실패가 없으면 사실만 남긴다.
    nonisolated static func deletionMessage(failedCount: Int, skippedCount: Int) -> String? {
        let failure = failureMessage(failedCount: failedCount)
        guard skippedCount > 0 else { return failure }
        let cancelled = "취소했습니다 — \(skippedCount)개 항목은 그대로 두었습니다."
        guard let failure else { return cancelled }
        return failure + " " + cancelled
    }
}
