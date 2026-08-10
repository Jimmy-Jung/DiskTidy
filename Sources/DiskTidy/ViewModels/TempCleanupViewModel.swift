import Foundation
import os

/// 완전 삭제는 `TempCandidate`의 identity를 삭제 시점까지 보존해야 한다.
/// `CleanableListViewModel`을 일반화하면 identity 없는 `CleanableItem`까지
/// 되돌릴 수 없는 삭제 계약에 섞이므로 재사용하지 않는다.
@MainActor
final class TempCleanupViewModel: ObservableObject {
    @Published var items: [TempCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isDeleting = false
    @Published var errorMessage: String?
    @Published private(set) var pendingRecoveries: [PermanentDeleter.QuarantineRecovery] = []

    /// 삭제 성공 뒤 표시할 요약. 회수량을 약속하지 않고 삭제한 경로 수와
    /// 새로 읽은 여유 용량을 따로 보여 준다.
    @Published private(set) var deletionSummary: String?

    /// 기존 `CleanableListViewModel`과 같은 방식으로 실제 수단만 주입 가능하게 둔다.
    /// 되돌릴 수 없는 삭제라 테스트가 진짜 파일시스템을 건드리면 안 되고,
    /// 스캔 실패·삭제 중 선택 변경 같은 상태 전이는 대역 없이는 고정할 수 없다.
    private let scan: @Sendable () -> Result<[TempCandidate], TempScanner.ScanError>
    private let delete: @Sendable (TempCandidate) -> PermanentDeleter.Outcome
    private let loadRecoveries: @Sendable () -> [PermanentDeleter.QuarantineRecovery]
    private let restoreRecovery: @Sendable (UUID) -> PermanentDeleter.RestoreOutcome
    private let availableBytes: @Sendable () -> Int64?

    init(
        scan: @escaping @Sendable () -> Result<[TempCandidate], TempScanner.ScanError> = {
            TempCleanupViewModel.runScan()
        },
        delete: @escaping @Sendable (TempCandidate) -> PermanentDeleter.Outcome = {
            PermanentDeleter.delete($0)
        },
        loadRecoveries: @escaping @Sendable () -> [PermanentDeleter.QuarantineRecovery] = {
            PermanentDeleter.pendingRecoveries()
        },
        restoreRecovery: @escaping @Sendable (UUID) -> PermanentDeleter.RestoreOutcome = {
            PermanentDeleter.restore($0)
        },
        availableBytes: @escaping @Sendable () -> Int64? = { StorageInfo.current()?.availableBytes }
    ) {
        self.scan = scan
        self.delete = delete
        self.loadRecoveries = loadRecoveries
        self.restoreRecovery = restoreRecovery
        self.availableBytes = availableBytes
    }

    var selectedItems: [TempCandidate] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    var isWorking: Bool { isScanning || isDeleting }

    func refresh() {
        // 재진입 가드가 없으면 스캔이 겹치고 늦게 끝난 오래된 결과가 최신을 덮어쓴다.
        guard !isWorking else { return }
        errorMessage = nil
        deletionSummary = nil
        isScanning = true

        let loadRecoveries = self.loadRecoveries
        let scan = self.scan
        Task {
            // 복구 대기 항목을 일반 스캔보다 먼저 읽고, 화면에도 먼저 올린다.
            // 26GB 트리 스캔은 수십 초 걸린다. 대입까지 미루면 그동안 복구 섹션이 비어 보인다.
            let recoveries = await Task.detached(priority: .userInitiated) { loadRecoveries() }.value
            self.pendingRecoveries = recoveries

            let outcome = await Task.detached(priority: .userInitiated) { scan() }.value
            switch outcome {
            case .success(let scanned):
                self.items = scanned
            case .failure(let error):
                // 스캔이 실패하면 이전 후보의 안전성을 더 이상 보증할 수 없다.
                // 목록을 비우지 않으면 검증되지 않은 항목에 삭제 버튼이 열린다.
                self.items = []
                self.errorMessage = Self.scanFailureMessage(error)
            }
            self.isScanning = false
        }
    }

    /// 되돌릴 수 없다. 반드시 확인 다이얼로그를 거친 뒤에만 호출한다.
    func deleteSelected() {
        guard !isWorking else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        isDeleting = true
        errorMessage = nil
        deletionSummary = nil

        let delete = self.delete
        let loadRecoveries = self.loadRecoveries
        let availableBytes = self.availableBytes
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                targets.map { (id: $0.id, outcome: delete($0)) }
            }.value
            // `StorageInfo`는 볼륨을 조회한다. 네트워크 볼륨이면 메인 스레드가 멈추고,
            // 삭제 직후라 사용자는 삭제 탓으로 오해한다.
            let (recoveries, available) = await Task.detached(priority: .userInitiated) {
                (loadRecoveries(), availableBytes())
            }.value

            // 삭제 중에도 체크박스는 열려 있다. 시작 시점에 스냅샷한 ID로만 목록을 줄인다.
            let deletedIDs = Set(results.filter { $0.outcome == .deleted }.map(\.id))
            // 격리까지만 간 항목은 원래 자리 상태를 더 이상 신뢰할 수 없다. 후보 목록에
            // 남겨 두면 다시 눌러도 원본이 없어 반복 실패하므로 복구 섹션에만 남긴다.
            let settledIDs = deletedIDs.union(
                results.filter { $0.outcome == .refused(.quarantineRecoveryRequired) }.map(\.id)
            )
            self.items.removeAll { settledIDs.contains($0.id) }
            self.pendingRecoveries = recoveries
            // 배너는 사유만 모아 보여 준다. 어느 항목이 왜 남았는지는 여기서만 남는다.
            for result in results where result.outcome != .deleted {
                Self.logger.error(
                    """
                    삭제하지 않음 \(result.id.canonicalPath, privacy: .private): \
                    \(String(describing: result.outcome), privacy: .public)
                    """
                )
            }
            self.errorMessage = Self.failureMessage(results.map(\.outcome))
            self.deletionSummary = Self.summary(
                deletedCount: deletedIDs.count,
                deletedBytes: targets.filter { deletedIDs.contains($0.id) }
                    .reduce(0) { $0 + $1.sizeBytes },
                availableBytes: available
            )
            self.isDeleting = false
        }
    }

    func selectAll(_ isSelected: Bool) {
        for index in items.indices { items[index].isSelected = isSelected }
    }

    /// journal ID만 넘긴다. 임의 경로 복원은 제공하지 않는다.
    func restore(_ recoveryID: UUID) {
        guard !isWorking else { return }
        isDeleting = true
        // 직전 삭제 요약을 남겨 두면 복원 결과처럼 읽힌다.
        deletionSummary = nil

        let restoreRecovery = self.restoreRecovery
        let loadRecoveries = self.loadRecoveries
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                restoreRecovery(recoveryID)
            }.value
            let recoveries = await Task.detached(priority: .userInitiated) { loadRecoveries() }.value

            self.pendingRecoveries = recoveries
            // 복원이 성공했다고 스캔 실패 배너를 지우면 목록이 빈 이유가 사라진다.
            self.errorMessage = Self.restoreFailureMessage(outcome) ?? self.errorMessage
            self.isDeleting = false
        }
    }

    private nonisolated static let logger = Logger(
        subsystem: "com.jimmy.disktidy", category: "temp-cleanup"
    )

    // MARK: - 문구 (순수 함수)

    private nonisolated static func runScan() -> Result<[TempCandidate], TempScanner.ScanError> {
        do {
            return .success(try TempScanner.scan())
        } catch let error as TempScanner.ScanError {
            return .failure(error)
        } catch {
            return .failure(.malformedOpenPathOutput)
        }
    }

    nonisolated static func scanFailureMessage(_ error: TempScanner.ScanError) -> String {
        switch error {
        case .invalidMinimumAge:
            return "보존 기간 설정이 잘못되어 스캔을 중단했습니다."
        case .inaccessibleRoot(let path):
            return "\(path)을(를) 열 수 없어 스캔을 중단했습니다. 목록을 비웁니다."
        case .openPathQueryFailed(let code):
            return "사용 중인 파일 목록(lsof)을 얻지 못했습니다 (종료 코드 \(code)). "
                + "사용 중 여부를 확인할 수 없어 목록을 비웁니다."
        case .malformedOpenPathOutput:
            return "사용 중인 파일 목록을 해석하지 못했습니다. "
                + "사용 중 여부를 확인할 수 없어 목록을 비웁니다."
        }
    }

    nonisolated static func failureMessage(_ outcomes: [PermanentDeleter.Outcome]) -> String? {
        var reasons: [String] = []
        var failedCount = 0

        for outcome in outcomes {
            switch outcome {
            case .deleted:
                continue
            case .refused(let refusal):
                let reason = description(of: refusal)
                if !reasons.contains(reason) { reasons.append(reason) }
                failedCount += 1
            case .failed(let code):
                let reason = "시스템 오류 (errno \(code))"
                if !reasons.contains(reason) { reasons.append(reason) }
                failedCount += 1
            }
        }

        guard failedCount > 0 else { return nil }
        return "\(failedCount)개 항목을 삭제하지 않았습니다: \(reasons.joined(separator: ", ")). "
            + "자세한 내용은 Console.app에서 DiskTidy 로그를 확인하세요."
    }

    nonisolated static func restoreFailureMessage(
        _ outcome: PermanentDeleter.RestoreOutcome
    ) -> String? {
        switch outcome {
        case .restored:
            return nil
        case .refused(let refusal):
            return "복원하지 않았습니다: \(description(of: refusal))."
        case .failed(let code):
            return "복원에 실패했습니다 (errno \(code))."
        }
    }

    nonisolated static func summary(
        deletedCount: Int, deletedBytes: Int64, availableBytes: Int64?
    ) -> String? {
        guard deletedCount > 0 else { return nil }
        let deleted = ByteCountFormatter.string(fromByteCount: deletedBytes, countStyle: .file)
        let free = availableBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "확인 불가"
        // 회수량을 약속하지 않는다. APFS 스냅샷이나 열린 파일 때문에 반영이 늦을 수 있다.
        return "경로 \(deletedCount)개 삭제 (대상 합계 \(deleted)). 현재 여유 용량 \(free). "
            + "APFS 스냅샷이나 열린 파일 때문에 여유 용량 반영이 늦어질 수 있습니다."
    }

    private nonisolated static func description(of refusal: PermanentDeleter.Refusal) -> String {
        switch refusal {
        case .outsideProductionRoot: return "정리 대상 경로 밖"
        case .identityChanged: return "스캔 이후 파일이 바뀜"
        case .inUse: return "사용 중이거나 사용 여부 확인 불가"
        case .unsafeTree: return "하위 항목 중 안전을 확인할 수 없는 것이 있음"
        case .quarantineUnavailable: return "격리 디렉터리를 쓸 수 없음"
        case .quarantineRecoveryRequired: return "격리 상태로 남음 — 복구 목록에서 처리 필요"
        }
    }
}
