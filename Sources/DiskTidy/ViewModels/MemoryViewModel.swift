import Foundation
import os

/// 개발 데몬 정리 탭의 상태. 지표는 자주, 프로세스 목록은 드물게 갱신한다.
///
/// `CleanableListViewModel`은 재사용하지 않는다. 항목이 경로·크기를 가진 파일이 아니라
/// 프로세스이고, 동작이 휴지통 이동이 아니라 되돌릴 수 없는 시그널 전송이다.
@MainActor
final class MemoryViewModel: ObservableObject {
    @Published private(set) var memory: Result<MemorySnapshot, MemoryInfo.Error>?
    @Published private(set) var swap: Result<SwapSnapshot, MemoryInfo.Error>?
    @Published private(set) var swapFileBytes: Result<Int64, MemoryInfo.Error>?

    @Published var processes: [RunningProcess] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isTerminating = false
    @Published var errorMessage: String?
    @Published private(set) var terminationSummary: String?

    /// 확인 다이얼로그가 떠 있는 동안 true. 사용자가 읽고 승인한 목록이 그 사이
    /// 바뀌면 다른 프로세스를 종료하게 되므로 자동 갱신을 멈춘다.
    @Published var isConfirming = false

    private let readMemory: @Sendable () -> Result<MemorySnapshot, MemoryInfo.Error>
    private let readSwap: @Sendable () -> Result<SwapSnapshot, MemoryInfo.Error>
    private let readSwapFiles: @Sendable () -> Result<Int64, MemoryInfo.Error>
    private let scanProcesses: @Sendable () -> Result<[RunningProcess], ProcessScanner.Error>
    private let sampleUsage: @Sendable (ProcessIdentity) -> ProcessUsage?
    private let terminate: @Sendable (RunningProcess) -> ProcessTerminator.Outcome

    /// identity별 관찰 기록. 목록이 갱신돼도 같은 프로세스면 이어 간다 — "유휴 40분"은 여기서 나온다.
    private var activityLog: [ProcessIdentity: ProcessActivity] = [:]

    /// timer는 하나만 소유한다. 지표 주기마다 깨어나고 그중 N번째에만 목록을 다시 읽는다.
    private var timer: Timer?
    /// `startPolling()`이 쓰는 주기. 테스트는 nil로 타이머 없이 상태 전이만 검증한다.
    private let metricsInterval: TimeInterval?
    private let processRefreshTickCount: Int
    private var ticksSinceProcessRefresh = 0

    /// 취소된 오래된 스캔이 최신 목록을 덮어쓰지 못하게 하는 세대 토큰.
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?

    init(
        metricsInterval: TimeInterval? = 5,
        processInterval: TimeInterval = 20,
        readMemory: @escaping @Sendable () -> Result<MemorySnapshot, MemoryInfo.Error> = {
            MemoryInfo.memory()
        },
        readSwap: @escaping @Sendable () -> Result<SwapSnapshot, MemoryInfo.Error> = {
            MemoryInfo.swap()
        },
        readSwapFiles: @escaping @Sendable () -> Result<Int64, MemoryInfo.Error> = {
            MemoryInfo.swapFileBytes()
        },
        scanProcesses: @escaping @Sendable () -> Result<[RunningProcess], ProcessScanner.Error> = {
            ProcessScanner.scan()
        },
        sampleUsage: @escaping @Sendable (ProcessIdentity) -> ProcessUsage? = {
            ProcessScanner.sampleUsage(of: $0)
        },
        terminate: @escaping @Sendable (RunningProcess) -> ProcessTerminator.Outcome = {
            ProcessTerminator.terminate($0)
        }
    ) {
        self.readMemory = readMemory
        self.readSwap = readSwap
        self.readSwapFiles = readSwapFiles
        self.scanProcesses = scanProcesses
        self.sampleUsage = sampleUsage
        self.terminate = terminate

        self.metricsInterval = metricsInterval
        let interval = metricsInterval ?? processInterval
        processRefreshTickCount = max(1, Int((processInterval / max(interval, 0.001)).rounded()))
    }

    /// 탭이 보일 때만 폴링한다. 이 객체는 창 수명 동안 살아 있으므로(`TabViewModels`),
    /// init에서 타이머를 걸면 탭을 한 번도 열지 않아도 5초마다 sysctl, 20초마다 ps가 돈다.
    func startPolling() {
        guard timer == nil, let metricsInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: metricsInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
        scanTask?.cancel()
    }

    // MARK: - 파생 상태

    var isWorking: Bool { isScanning || isTerminating }

    /// 종료 버튼이 실제로 다루는 대상. 선택돼 있어도 정책을 통과하지 못하면 제외된다.
    var terminableSelection: [RunningProcess] {
        processes.filter { $0.isSelected && $0.isTerminable }
    }

    var selectedCount: Int { processes.filter(\.isSelected).count }

    /// 스왑 파일 안내 배너를 띄울지. 측정 실패는 배너 대상이 아니다.
    var showsSwapFileNotice: Bool {
        guard case .success(let bytes) = swapFileBytes else { return false }
        return bytes > MemoryInfo.swapFileNoticeThreshold
    }

    // MARK: - 갱신

    func refreshAll() {
        refreshMetrics()
        refreshProcesses()
    }

    private func tick() {
        refreshMetrics()
        ticksSinceProcessRefresh += 1
        guard ticksSinceProcessRefresh >= processRefreshTickCount else {
            // 목록은 20초마다지만 활동 표본은 5초마다 갱신한다. `ps` 없이 syscall만 돈다.
            refreshActivity()
            return
        }
        ticksSinceProcessRefresh = 0
        refreshProcesses()
    }

    /// 목록에 있는 프로세스의 활동 표본만 다시 읽어 관찰 기록을 잇는다.
    func refreshActivity() {
        guard !isWorking, !processes.isEmpty else { return }
        let identities = processes.map(\.identity)
        let sampleUsage = self.sampleUsage
        // 표본 시각은 채취 **전에** 잡는다. 완료 시각으로 적으면, 그 사이 목록 갱신이 더 새 표본을
        // 기록했을 때 옛 표본이 새 시각을 달고 덮어써 다음 관찰에서 헛 "활동 중"이 뜬다.
        let sampledAt = Date()
        Task {
            let samples = await Task.detached(priority: .utility) {
                identities.map { ($0, sampleUsage($0)) }
            }.value
            // 갱신 사이에 목록이 바뀌었을 수 있다. identity로 찾아 넣고, 한 번에 대입해 발행을 한 번으로 줄인다.
            var updated = self.processes
            for (identity, usage) in samples {
                guard let usage, let index = updated.firstIndex(where: { $0.identity == identity }) else { continue }
                // 더 새 관찰이 이미 있으면 이 표본은 낡았다. 버린다.
                if let previous = activityLog[identity], previous.observedAt >= sampledAt { continue }
                let activity = ProcessActivity.observe(previous: activityLog[identity], current: usage, now: sampledAt)
                activityLog[identity] = activity
                updated[index].usage = usage
                updated[index].activity = activity
            }
            self.processes = updated
        }
    }

    /// 세 지표는 서로 독립이다. 하나가 실패해도 나머지는 계속 표시한다.
    func refreshMetrics() {
        let readMemory = self.readMemory
        let readSwap = self.readSwap
        let readSwapFiles = self.readSwapFiles
        Task {
            // sysctl과 VM 볼륨 열거는 메인 스레드를 잡을 수 있다.
            let values = await Task.detached(priority: .utility) {
                (readMemory(), readSwap(), readSwapFiles())
            }.value
            self.memory = values.0
            self.swap = values.1
            self.swapFileBytes = values.2
        }
    }

    func refreshProcesses() {
        // 확인창이나 종료가 진행 중이면 목록을 바꾸지 않는다.
        guard !isConfirming, !isWorking else { return }

        isScanning = true
        errorMessage = nil
        scanGeneration += 1
        let generation = scanGeneration

        let scanProcesses = self.scanProcesses
        scanTask?.cancel()
        scanTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) { scanProcesses() }.value
            // 늦게 끝난 오래된 스캔이 최신 결과를 덮으면 이미 종료한 프로세스가 되살아난다.
            guard !Task.isCancelled, generation == self.scanGeneration else { return }

            switch outcome {
            case .success(let scanned):
                // 갱신 사이에도 체크 상태는 유지한다. identity가 같은 것만 이어 받는다.
                let selected = Set(self.processes.filter(\.isSelected).map(\.identity))
                let now = Date()
                var log: [ProcessIdentity: ProcessActivity] = [:]
                self.processes = scanned.map { process in
                    var updated = process
                    updated.isSelected = selected.contains(process.identity)
                    if let usage = process.usage {
                        let activity = ProcessActivity.observe(
                            previous: self.activityLog[process.identity], current: usage, now: now
                        )
                        log[process.identity] = activity
                        updated.activity = activity
                    }
                    return updated
                }
                // 사라진 프로세스의 기록은 버린다. PID가 재사용돼도 identity(시작 시각)가 달라 섞이지 않는다.
                self.activityLog = log
            case .failure(let error):
                // 스캔이 실패하면 이전 목록의 identity를 더 이상 보증할 수 없다.
                // 남겨 두면 검증되지 않은 대상에 종료 버튼이 열린다.
                self.processes = []
                self.errorMessage = Self.scanFailureMessage(error)
            }
            self.isScanning = false
        }
    }

    func selectAll(_ isSelected: Bool) {
        for index in processes.indices { processes[index].isSelected = isSelected }
    }

    // MARK: - 종료

    /// 되돌릴 수 없다. 반드시 확인 다이얼로그를 거친 뒤에만 호출한다.
    func terminateSelected() {
        guard !isWorking else { return }
        let targets = terminableSelection
        guard !targets.isEmpty else { return }

        isTerminating = true
        errorMessage = nil
        terminationSummary = nil

        let terminate = self.terminate
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                targets.map { (name: $0.displayName, outcome: terminate($0)) }
            }.value

            for result in results where !Self.isSuccess(result.outcome) {
                Self.logger.error(
                    """
                    종료하지 않음 \(result.name, privacy: .public): \
                    \(String(describing: result.outcome), privacy: .public)
                    """
                )
            }

            self.terminationSummary = Self.summary(results.map(\.outcome))
            self.errorMessage = Self.failureMessage(results.map(\.outcome))
            self.isTerminating = false
            // 종료 뒤 목록·지표를 정확히 한 번 다시 읽는다.
            self.refreshAll()
        }
    }

    private nonisolated static let logger = Logger(
        subsystem: "com.jimmy.disktidy", category: "memory-cleanup"
    )

    // MARK: - 문구 (순수 함수)

    nonisolated static func isSuccess(_ outcome: ProcessTerminator.Outcome) -> Bool {
        switch outcome {
        case .terminated, .killed, .alreadyGone: return true
        case .notPermitted, .refused, .failed: return false
        }
    }

    nonisolated static func scanFailureMessage(_ error: ProcessScanner.Error) -> String {
        switch error {
        case .listFailed(let code):
            return "프로세스 목록을 얻지 못했습니다 (ps 종료 코드 \(code)). 목록을 비웁니다."
        case .malformedOutput:
            return "프로세스 목록을 해석하지 못했습니다. 목록을 비웁니다."
        }
    }

    /// 회수량을 약속하지 않는다. RSS는 근사치이고 압축·공유 페이지가 반영되지 않는다.
    nonisolated static func summary(_ outcomes: [ProcessTerminator.Outcome]) -> String? {
        let terminated = outcomes.filter { $0 == .terminated }.count
        let killed = outcomes.filter { $0 == .killed }.count
        let alreadyGone = outcomes.filter { $0 == .alreadyGone }.count
        guard terminated + killed + alreadyGone > 0 else { return nil }

        var parts = ["정상 종료 \(terminated)개"]
        if killed > 0 { parts.append("강제 종료 \(killed)개") }
        if alreadyGone > 0 { parts.append("이미 종료됨 \(alreadyGone)개") }
        return parts.joined(separator: ", ")
            + ". 회수된 메모리는 표시된 RSS 근사치와 다를 수 있습니다."
    }

    nonisolated static func failureMessage(_ outcomes: [ProcessTerminator.Outcome]) -> String? {
        var reasons: [String] = []
        var failedCount = 0

        for outcome in outcomes where !isSuccess(outcome) {
            let reason = description(of: outcome)
            if !reasons.contains(reason) { reasons.append(reason) }
            failedCount += 1
        }

        guard failedCount > 0 else { return nil }
        return "\(failedCount)개 프로세스를 종료하지 않았습니다: \(reasons.joined(separator: ", ")). "
            + "자세한 내용은 Console.app에서 DiskTidy 로그를 확인하세요."
    }

    private nonisolated static func description(of outcome: ProcessTerminator.Outcome) -> String {
        switch outcome {
        case .terminated: return "정상 종료"
        case .killed: return "강제 종료"
        case .alreadyGone: return "이미 종료됨"
        case .notPermitted: return "권한 없음"
        case .failed(let code): return "시스템 오류 (errno \(code))"
        case .refused(let refusal):
            switch refusal {
            case .notTerminable: return "종료 조건을 만족하지 않음"
            case .identityChanged: return "스캔 이후 다른 프로세스로 바뀜"
            case .daemonEvidenceChanged: return "데몬 근거가 바뀌었거나 읽을 수 없음"
            case .protectedProcess: return "보호 프로세스"
            }
        }
    }
}
