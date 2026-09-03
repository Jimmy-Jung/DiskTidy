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
