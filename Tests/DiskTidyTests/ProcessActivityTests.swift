import Foundation
import Testing

@testable import DiskTidy

// MARK: - 관찰 판정 (순수 함수)

@Suite("프로세스 활동 관찰")
struct ProcessActivityObservationTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(cpu: TimeInterval, disk: Int64 = 0, running: Int = 0) -> ProcessUsage {
        ProcessUsage(cpuSeconds: cpu, diskBytes: disk, runningThreads: running, parentPID: 1, parentExecutablePath: "/sbin/launchd")
    }

    @Test("첫 관찰은 실행 중 스레드로만 판단한다")
    func firstObservationUsesRunningThreads() {
        let idle = ProcessActivity.observe(previous: nil, current: usage(cpu: 100), now: base)
        #expect(!idle.isActiveNow)
        #expect(idle.lastActive == nil)
        #expect(idle.firstObserved == base)

        let busy = ProcessActivity.observe(previous: nil, current: usage(cpu: 100, running: 2), now: base)
        #expect(busy.isActiveNow)
        #expect(busy.lastActive == base)
    }

    @Test("관찰 간격 대비 2% 넘게 CPU를 썼으면 활동, 그 아래는 유휴 JVM 잡음이다")
    func cpuShareDecidesActivity() {
        let first = ProcessActivity.observe(previous: nil, current: usage(cpu: 100), now: base)
        let later = base.addingTimeInterval(20)

        let noise = ProcessActivity.observe(previous: first, current: usage(cpu: 100.05), now: later)
        #expect(!noise.isActiveNow)
        #expect(noise.lastActive == nil)
        #expect(noise.firstObserved == base)

        let work = ProcessActivity.observe(previous: first, current: usage(cpu: 101), now: later)
        #expect(work.isActiveNow)
        #expect(work.lastActive == later)
    }

    @Test("디스크 I/O만 있어도 활동이고, 조용해지면 마지막 활동 시각은 남는다")
    func diskCountsAndLastActiveSticks() {
        let first = ProcessActivity.observe(previous: nil, current: usage(cpu: 1), now: base)
        let io = ProcessActivity.observe(previous: first, current: usage(cpu: 1, disk: 2_000_000), now: base.addingTimeInterval(5))
        #expect(io.isActiveNow)

        let quiet = ProcessActivity.observe(previous: io, current: usage(cpu: 1, disk: 2_000_000), now: base.addingTimeInterval(605))
        #expect(!quiet.isActiveNow)
        #expect(quiet.lastActive == base.addingTimeInterval(5))
        #expect(quiet.statusString(now: base.addingTimeInterval(605)) == "유휴 10분")
    }

    @Test("순서가 어긋나 누적치가 줄어 보이면 활동으로 치지 않는다")
    func negativeDeltaIsNotActivity() {
        let first = ProcessActivity.observe(previous: nil, current: usage(cpu: 100, disk: 5_000_000), now: base)
        let earlierSample = ProcessActivity.observe(previous: first, current: usage(cpu: 90, disk: 1_000_000), now: base.addingTimeInterval(5))
        #expect(!earlierSample.isActiveNow)
    }

    @Test("상태 문구: 활동 중 / 관찰 중 / 관찰 N분 동안 활동 없음")
    func statusStrings() {
        let first = ProcessActivity.observe(previous: nil, current: usage(cpu: 1), now: base)
        #expect(first.statusString(now: base.addingTimeInterval(30)) == "관찰 중")
        #expect(first.statusString(now: base.addingTimeInterval(2_400)) == "관찰 40분 동안 활동 없음")
        let busy = ProcessActivity.observe(previous: nil, current: usage(cpu: 1, running: 1), now: base)
        #expect(busy.statusString(now: base) == "활동 중")
    }
}

// MARK: - 문구

@Suite("프로세스 활동 문구")
struct ProcessActivityTextTests {
    @Test("기간은 가장 큰 단위 둘만 보인다")
    func shortDurations() {
        #expect(DurationText.short(30) == "1분 미만")
        #expect(DurationText.short(8 * 60) == "8분")
        #expect(DurationText.short(3 * 3600 + 12 * 60) == "3시간 12분")
        #expect(DurationText.short(2 * 86_400 + 4 * 3600 + 59 * 60) == "2일 4시간")
        #expect(DurationText.short(-5) == "1분 미만")
    }

    @Test("CPU 누적은 작은 값은 소수, 큰 값은 분·시간이다")
    func cpuDurations() {
        #expect(DurationText.cpu(28.79) == "28.8초")
        #expect(DurationText.cpu(243) == "4분 3초")
        #expect(DurationText.cpu(4_320) == "1시간 12분")
    }

    @Test("띄운 앱은 헬퍼가 아니라 첫 .app 이름으로 보인다")
    func parentAppNames() {
        #expect(ProcessUsage.appName(forExecutablePath:
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        ) == "Visual Studio Code")
        #expect(ProcessUsage.appName(forExecutablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode") == "Xcode")
        #expect(ProcessUsage.appName(forExecutablePath: "/bin/zsh") == "zsh")

        let orphan = ProcessUsage(cpuSeconds: 0, diskBytes: 0, runningThreads: 0, parentPID: 1, parentExecutablePath: "/sbin/launchd")
        #expect(orphan.parentDisplayName.contains("독립 실행"))
        let gone = ProcessUsage(cpuSeconds: 0, diskBytes: 0, runningThreads: 0, parentPID: 4242, parentExecutablePath: nil)
        #expect(gone.parentDisplayName == "부모 종료됨")
    }

    @Test("실행 파일 이름이 버전 번호인 에이전트는 프로세스 이름으로 보인다")
    func agentParentsUseProcessName() {
        let claude = ProcessUsage(
            cpuSeconds: 0, diskBytes: 0, runningThreads: 0, parentPID: 15334,
            parentExecutablePath: "/Users/me/.local/share/claude/versions/2.1.259",
            parentProcessName: "claude"
        )
        #expect(claude.parentDisplayName == "Claude Code")
        let codex = ProcessUsage(
            cpuSeconds: 0, diskBytes: 0, runningThreads: 0, parentPID: 3813,
            parentExecutablePath: "/Users/me/.vscode/extensions/openai.chatgpt-1/bin/codex",
            parentProcessName: "codex"
        )
        #expect(codex.parentDisplayName == "Codex")
        // .app 안의 헬퍼는 여전히 앱 이름이 이긴다.
        let helper = ProcessUsage(
            cpuSeconds: 0, diskBytes: 0, runningThreads: 0, parentPID: 3601,
            parentExecutablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            parentProcessName: "Code Helper (Plugin)"
        )
        #expect(helper.parentDisplayName == "Visual Studio Code")
    }

    @Test("dart는 하위 명령으로, adb는 서버로 분류한다")
    func dartAndAdbLabels() {
        let dart = ProcessIdentity(
            pid: 1, uid: getuid(), startTime: ProcessStartTime(seconds: 0, microseconds: 0),
            executablePath: "/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart"
        )
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "mcp-server"]) == "MCP 서버")
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "language-server", "--protocol=lsp"]) == "Dart 분석 서버")
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "tooling-daemon", "--machine"]) == "Dart 도구 데몬")
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "devtools", "--machine"]) == "Dart DevTools")
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "--enable-asserts", "run"]) == "Dart/Flutter")
        #expect(ProcessScanner.activeWorkloadLabel(for: dart, arguments: ["dart", "pub", "get"]) == "Dart pub")

        let adb = ProcessIdentity(
            pid: 2, uid: getuid(), startTime: ProcessStartTime(seconds: 0, microseconds: 0),
            executablePath: "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
        )
        #expect(ProcessScanner.activeWorkloadLabel(for: adb, arguments: ["adb", "-L", "tcp:5037", "fork-server", "server"])?.hasPrefix("adb 서버") == true)
    }
}

// MARK: - 뷰모델이 관찰을 이어 간다

@MainActor
@Suite("개발 데몬 활동 갱신")
struct MemoryActivityRefreshTests {
    private final class UsageFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var cpu: TimeInterval = 100
        func advance(by seconds: TimeInterval) { lock.lock(); cpu += seconds; lock.unlock() }
        func sample() -> ProcessUsage {
            lock.lock(); defer { lock.unlock() }
            return ProcessUsage(cpuSeconds: cpu, diskBytes: 0, runningThreads: 0, parentPID: 1, parentExecutablePath: "/sbin/launchd")
        }
    }

    private func process(feed: UsageFeed) -> RunningProcess {
        let identity = ProcessIdentity(
            pid: 99_991, uid: getuid(),
            startTime: ProcessStartTime(seconds: 1_786_000_000, microseconds: 1),
            executablePath: "/usr/bin/java"
        )
        return RunningProcess(
            identity: identity, residentBytes: 1024, arguments: ["java"], displayName: "java",
            kind: .devDaemon(.gradle), usage: feed.sample()
        )
    }

    @Test("스캔이 표본을 주면 관찰이 시작되고, 활동 갱신에서 CPU가 뛰면 활동 중으로 바뀐다")
    func observesAcrossRefreshes() async {
        let feed = UsageFeed()
        // 스캔 클로저는 @Sendable이라 메인 액터 헬퍼를 부를 수 없다. 값을 먼저 만들어 넘긴다.
        let scanned = [process(feed: feed)]
        let viewModel = MemoryViewModel(
            metricsInterval: nil,
            readMemory: { .failure(.hostStatistics(1)) },
            readSwap: { .failure(.swapUsage(1)) },
            readSwapFiles: { .failure(.vmDirectory(1)) },
            scanProcesses: { .success(scanned) },
            sampleUsage: { _ in feed.sample() },
            terminate: { _ in .failed(1) }
        )

        viewModel.refreshProcesses()
        #expect(await waitUntil { viewModel.processes.first?.activity != nil })
        #expect(viewModel.processes.first?.activity?.isActiveNow == false)

        // 5초 표본 사이에 CPU 60초를 썼다 — 간격이 아주 짧아도 2%를 훌쩍 넘는다.
        feed.advance(by: 60)
        viewModel.refreshActivity()
        #expect(await waitUntil { viewModel.processes.first?.activity?.isActiveNow == true })
        #expect(viewModel.processes.first?.activity?.lastActive != nil)
        #expect(viewModel.processes.first?.usage?.cpuSeconds == 160)
    }
}

// MARK: - 실제 프로세스 표본

@Suite("실제 프로세스 활동 표본")
struct LiveProcessUsageTests {
    @Test("자기 프로세스의 표본을 읽는다 — CPU·부모·실행 중 스레드가 채워진다")
    func samplesOwnProcess() throws {
        guard case .verified(let identity, _, _) = ProcessScanner.snapshot(pid: getpid()) else {
            Issue.record("자기 프로세스의 identity를 읽지 못했다")
            return
        }
        let usage = try #require(ProcessScanner.sampleUsage(of: identity))
        // 테스트 러너가 여기까지 오는 데 CPU를 썼고, 지금 이 스레드가 실행 중이다.
        #expect(usage.cpuSeconds > 0)
        #expect(usage.cpuSeconds < 3600)   // timebase 환산이 틀리면 수십 배로 튄다
        #expect(usage.runningThreads >= 1)
        #expect(usage.parentPID > 0)
        #expect(usage.parentExecutablePath?.hasPrefix("/") == true)
    }

    @Test("identity가 달라진 pid는 표본을 주지 않는다")
    func refusesReusedPID() throws {
        guard case .verified(let identity, _, _) = ProcessScanner.snapshot(pid: getpid()) else { return }
        let stale = ProcessIdentity(
            pid: identity.pid, uid: identity.uid,
            startTime: ProcessStartTime(seconds: identity.startTime.seconds - 1, microseconds: 0),
            executablePath: identity.executablePath
        )
        #expect(ProcessScanner.sampleUsage(of: stale) == nil)
    }
}
