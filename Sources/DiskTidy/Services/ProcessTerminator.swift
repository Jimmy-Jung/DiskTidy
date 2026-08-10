import Darwin
import Foundation
import os

/// 되돌릴 수 없는 프로세스 종료. 호출 전 반드시 사용자 확인을 거친다.
///
/// 목록에 있던 PID는 확인창을 보는 동안 다른 프로세스에 재사용될 수 있다. 그래서
/// **스캔 시점 정보만으로는 어떤 시그널도 보내지 않는다.** 시그널 직전에 identity와
/// argv를 다시 읽고, UI가 쓰는 것과 같은 `TerminationPolicy`를 다시 통과시킨다.
/// SIGKILL로 올리기 전에도 같은 검증을 반복한다.
enum ProcessTerminator {
    private static let logger = Logger(subsystem: "com.jimmy.disktidy", category: "process-kill")

    /// 생존 확인 간격. Gradle 데몬은 SIGTERM 뒤 정리에 수백 ms를 쓴다.
    static let pollInterval: TimeInterval = 0.05

    enum Refusal: Equatable {
        case notTerminable
        case identityChanged
        case daemonEvidenceChanged
        case protectedProcess
    }

    enum Outcome: Equatable {
        case terminated
        case killed
        case alreadyGone
        case notPermitted
        case refused(Refusal)
        case failed(Int32)
    }

    /// `kill(pid, 0)` 결과. "없음"과 "권한 없음"을 접으면 남아 있는 프로세스를
    /// 종료 성공으로 표시한다.
    enum Liveness: Equatable {
        case alive
        case gone
        case notPermitted
        case failed(Int32)
    }

    /// 시그널·대기·재검증 수단. 기본값이 곧 production 동작이며,
    /// 테스트는 실제 프로세스를 죽이지 않고 순서와 거부 조건만 검증한다.
    struct Signals {
        /// 반환 0은 성공, 그 외에는 보존한 `errno`.
        var send: @Sendable (Int32, Int32) -> Int32
        var liveness: @Sendable (Int32) -> Liveness
        var revalidate: @Sendable (ProcessIdentity) -> ProcessScanner.Revalidation
        var wait: @Sendable (TimeInterval) -> Void

        static let system = Signals(
            send: { pid, signal in Darwin.kill(pid, signal) == 0 ? 0 : errno },
            liveness: { pid in
                guard Darwin.kill(pid, 0) != 0 else { return .alive }
                switch errno {
                case ESRCH: return .gone
                case EPERM: return .notPermitted
                default: return .failed(errno)
                }
            },
            revalidate: { ProcessScanner.revalidate(matching: $0) },
            wait: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    /// 재검증이 실패하면 어떤 시그널도 보내지 않는다.
    static func terminate(
        _ process: RunningProcess,
        gracePeriod: TimeInterval = 3,
        signals: Signals = .system
    ) -> Outcome {
        // 이미 사라진 PID를 재검증에 넣으면 `.identityChanged`로 보고돼
        // "다른 프로세스가 됐다"는 잘못된 경고가 뜬다. 생존 확인을 먼저 한다.
        switch signals.liveness(process.identity.pid) {
        case .gone: return .alreadyGone
        case .notPermitted: return .notPermitted
        case .failed(let code): return .failed(code)
        case .alive: break
        }

        if let refusal = refusal(for: process, signals: signals) {
            logger.error(
                """
                종료하지 않음 pid \(process.identity.pid, privacy: .public): \
                \(String(describing: refusal), privacy: .public)
                """
            )
            return .refused(refusal)
        }

        let termCode = signals.send(process.identity.pid, SIGTERM)
        guard termCode == 0 else {
            return termCode == ESRCH ? .alreadyGone : .failed(termCode)
        }

        var waited: TimeInterval = 0
        while waited < gracePeriod {
            signals.wait(pollInterval)
            waited += pollInterval
            switch signals.liveness(process.identity.pid) {
            case .gone: return .terminated
            case .notPermitted: return .notPermitted
            case .failed(let code): return .failed(code)
            case .alive: continue
            }
        }

        // 유예 동안 PID가 재사용됐을 수 있다. SIGKILL은 훨씬 파괴적이므로 다시 확인한다.
        if let refusal = refusal(for: process, signals: signals) { return .refused(refusal) }

        let killCode = signals.send(process.identity.pid, SIGKILL)
        guard killCode == 0 else {
            // 그 사이 스스로 끝났다. SIGKILL은 실제로 전달되지 않았다.
            return killCode == ESRCH ? .terminated : .failed(killCode)
        }
        return .killed
    }

    /// identity A → argv → identity B를 다시 수행하고 같은 `TerminationPolicy`를 적용한다.
    /// 통과하면 nil, 아니면 거부 사유.
    private static func refusal(for process: RunningProcess, signals: Signals) -> Refusal? {
        switch signals.revalidate(process.identity) {
        case .identityChanged:
            return .identityChanged
        case .daemonEvidenceUnavailable:
            return .daemonEvidenceChanged
        case .verified(let identity, let arguments, let kind):
            if TerminationPolicy.isProtected(identity) { return .protectedProcess }
            guard TerminationPolicy.canTerminate(
                identity: identity, kind: kind, arguments: arguments
            ) else {
                // 데몬 근거가 사라진 경우와 정책 자체가 막는 경우를 구분해 보고한다.
                guard case .devDaemon = kind else { return .daemonEvidenceChanged }
                return .notTerminable
            }
            return nil
        }
    }
}
