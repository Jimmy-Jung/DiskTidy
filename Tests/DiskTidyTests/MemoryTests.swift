import Darwin
import Foundation
import Testing

@testable import DiskTidy

// MARK: - 픽스처

private let javaPath = "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"

/// 실측한 Gradle 8.13 데몬 argv. `--add-opens=`·`-javaagent:` 형태가 실제로 온다.
private let gradleArguments = [
    javaPath,
    "--add-opens=java.base/java.lang=ALL-UNNAMED",
    "--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
    "-Xmx4g",
    "-Duser.language=ko",
    "-cp", "/Users/tester/.gradle/gradle-8.13/lib/gradle-daemon-main-8.13.jar",
    "-javaagent:/Users/tester/.gradle/gradle-8.13/lib/agents/instrumentation-agent.jar",
    "org.gradle.launcher.daemon.bootstrap.GradleDaemon",
    "8.13"
]

/// 실측한 Kotlin 2.2.21 데몬 argv. `--add-exports`가 **분리형**으로 온다.
private let kotlinArguments = [
    javaPath,
    "-cp", "/Users/tester/.gradle/caches/kotlin-compiler-embeddable-2.2.21.jar",
    "-Djava.awt.headless=true",
    "-Xmx4g",
    "-XX:ReservedCodeCacheSize=320m",
    "-ea",
    "-XX:+UseParallelGC",
    "--add-exports", "java.base/sun.nio.ch=ALL-UNNAMED",
    "org.jetbrains.kotlin.daemon.KotlinCompileDaemon",
    "--daemon-autoshutdownIdleSeconds=7200"
]

private func makeIdentity(
    pid: Int32 = 99_991,
    uid: uid_t = getuid(),
    path: String = javaPath,
    seconds: Int64 = 1_786_000_000,
    microseconds: Int32 = 424_242
) -> ProcessIdentity {
    ProcessIdentity(
        pid: pid,
        uid: uid,
        startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
        executablePath: path
    )
}

private func makeProcess(
    identity: ProcessIdentity = makeIdentity(),
    arguments: [String] = gradleArguments,
    kind: ProcessKind = .devDaemon(.gradle)
) -> RunningProcess {
    RunningProcess(
        identity: identity,
        residentBytes: 4 * 1024 * 1024 * 1024,
        arguments: arguments,
        displayName: identity.executableName,
        kind: kind
    )
}

/// `KERN_PROCARGS2` 버퍼를 합성한다: argc + 실행 경로 + NUL 패딩 + 인자들.
private func makeProcArgsBuffer(
    argc: Int32, executablePath: String, arguments: [String], padding: Int = 3,
    terminateLast: Bool = true
) -> Data {
    var data = Data()
    withUnsafeBytes(of: argc) { data.append(contentsOf: $0) }
    data.append(contentsOf: Array(executablePath.utf8))
    data.append(contentsOf: [UInt8](repeating: 0, count: padding + 1))
    for (index, argument) in arguments.enumerated() {
        data.append(contentsOf: Array(argument.utf8))
        if index < arguments.count - 1 || terminateLast { data.append(0) }
    }
    return data
}

// MARK: - 대역

/// 호출 순서대로 값을 돌려주는 identity 대역. 마지막 값 이후에는 그 값을 반복한다.
private final class IdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [ProcessIdentity?]
    private var index = 0

    init(_ values: [ProcessIdentity?]) { self.values = values }

    func next() -> ProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

/// 보낸 시그널을 기록하는 대역. 실제 프로세스에는 아무것도 보내지 않는다.
private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    private var probes = 0

    /// SIGTERM을 받은 뒤 몇 번째 생존 확인부터 `.gone`이 될지. nil이면 끝까지 살아 있다.
    private let goesAwayAfterProbe: Int?
    private let failingSignals: [Int32: Int32]
    private let permissionDenied: Bool

    init(
        goesAwayAfterProbe: Int? = 1,
        failingSignals: [Int32: Int32] = [:],
        permissionDenied: Bool = false
    ) {
        self.goesAwayAfterProbe = goesAwayAfterProbe
        self.failingSignals = failingSignals
        self.permissionDenied = permissionDenied
    }

    func send(_ pid: Int32, _ signal: Int32) -> Int32 {
        lock.lock()
        recorded.append(signal)
        lock.unlock()
        return failingSignals[signal] ?? 0
    }

    func liveness(_ pid: Int32) -> ProcessTerminator.Liveness {
        lock.lock()
        defer { lock.unlock() }
        if permissionDenied { return .notPermitted }
        // 첫 호출은 시그널 전 사전 확인이라 항상 살아 있어야 한다.
        guard probes > 0 else {
            probes += 1
            return .alive
        }
        probes += 1
        guard let threshold = goesAwayAfterProbe else { return .alive }
        return probes > threshold ? .gone : .alive
    }

    var sentSignals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 프로세스 스캔 호출 횟수를 기록하는 대역.
private final class ProcessScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: Result<[RunningProcess], ProcessScanner.Error>

    init(result: Result<[RunningProcess], ProcessScanner.Error> = .success([])) {
        self.result = result
    }

    func scan() -> Result<[RunningProcess], ProcessScanner.Error> {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// 종료 호출을 기록하는 대역.
private final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    private let outcome: ProcessTerminator.Outcome

    init(outcome: ProcessTerminator.Outcome = .terminated) { self.outcome = outcome }

    func terminate(_ process: RunningProcess) -> ProcessTerminator.Outcome {
        lock.lock()
        recorded.append(process.identity.pid)
        lock.unlock()
        return outcome
    }

    var terminatedPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - ps 출력 파싱

@Suite("ps 출력 파싱")
struct ProcessListParsingTests {
    @Test("정상 3줄은 pid와 rss로 정확히 분리된다")
    func parsesNormalRows() throws {
        let rows = try ProcessScanner.parseProcessList("  4631 1048576\n38675  524288\n99991 4096\n")
        #expect(rows.count == 3)
        #expect(rows[0].pid == 4631)
        #expect(rows[0].residentKB == 1_048_576)
        #expect(rows[2].pid == 99991)
        #expect(rows[2].residentKB == 4096)
    }

    @Test("빈 줄과 헤더 잔여물은 무시한다")
    func ignoresBlankAndHeaderLines() throws {
        let rows = try ProcessScanner.parseProcessList("  PID   RSS\n\n  4631 1024\n   \n")
        #expect(rows.count == 1)
        #expect(rows[0].pid == 4631)
    }

    @Test(
        "숫자가 아닌 필드·음수·overflow·필드 수 불일치는 파싱 실패다",
        arguments: [
            "abc 1024",          // pid가 숫자가 아님
            "4631 xyz",          // rss가 숫자가 아님
            "-1 1024",           // 음수 pid
            "4631 -5",           // 음수 rss
            "99999999999 1024",  // Int32 overflow
            "4631 1024 extra",   // 필드 수 초과
            "4631"               // 필드 수 부족
        ]
    )
    func rejectsMalformedRows(line: String) {
        #expect(throws: ProcessScanner.Error.malformedOutput) {
            _ = try ProcessScanner.parseProcessList(line)
        }
    }
}

// MARK: - KERN_PROCARGS2 파싱

@Suite("KERN_PROCARGS2 argv 파싱")
struct ProcArgsParsingTests {
    @Test("argc개 인자를 NUL 패딩 뒤에서 정확히 읽는다")
    func parsesArguments() {
        let data = makeProcArgsBuffer(
            argc: 3, executablePath: javaPath, arguments: [javaPath, "-Xmx4g", "MainClass"]
        )
        #expect(ProcessScanner.parseProcArgs(data) == [javaPath, "-Xmx4g", "MainClass"])
    }

    @Test("argc보다 인자가 적으면 부분 결과를 쓰지 않고 nil이다")
    func rejectsTruncatedArgumentCount() {
        let data = makeProcArgsBuffer(
            argc: 4, executablePath: javaPath, arguments: [javaPath, "-Xmx4g"]
        )
        #expect(ProcessScanner.parseProcArgs(data) == nil)
    }

    @Test("마지막 인자에 종결 NUL이 없으면 잘린 출력으로 보고 nil이다")
    func rejectsMissingTerminator() {
        let data = makeProcArgsBuffer(
            argc: 2, executablePath: javaPath, arguments: [javaPath, "MainClass"],
            terminateLast: false
        )
        #expect(ProcessScanner.parseProcArgs(data) == nil)
    }

    @Test("argc가 0 이하이거나 헤더만 있으면 nil이다")
    func rejectsInvalidHeader() {
        #expect(ProcessScanner.parseProcArgs(Data([0, 0, 0, 0])) == nil)
        #expect(ProcessScanner.parseProcArgs(Data([1, 0])) == nil)
        let negative = makeProcArgsBuffer(
            argc: -1, executablePath: javaPath, arguments: [javaPath]
        )
        #expect(ProcessScanner.parseProcArgs(negative) == nil)
    }

    @Test("비UTF-8 바이트가 섞이면 nil이다")
    func rejectsInvalidUTF8() {
        var data = Data()
        withUnsafeBytes(of: Int32(1)) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("/bin/x".utf8))
        data.append(0)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(0)
        #expect(ProcessScanner.parseProcArgs(data) == nil)
    }
}

// MARK: - 분류

@Suite("identity-bound argv와 분류")
struct ClassificationTests {
    @Test("Gradle 데몬 argv는 devDaemon(.gradle)이 된다")
    func classifiesGradle() {
        #expect(
            ProcessScanner.classify(identity: makeIdentity(), arguments: gradleArguments)
                == .devDaemon(.gradle)
        )
    }

    @Test("Kotlin 컴파일 데몬 argv는 devDaemon(.kotlin)이 된다")
    func classifiesKotlin() {
        #expect(
            ProcessScanner.classify(identity: makeIdentity(), arguments: kotlinArguments)
                == .devDaemon(.kotlin)
        )
    }

    /// 회귀 방지 핵심: 문자열 포함 검사로 되돌아가면 이 테스트가 깨진다.
    @Test("다른 main class 뒤 일반 인자에 데몬 문자열이 있어도 devDaemon이 아니다")
    func rejectsDaemonStringInPlainArguments() {
        let arguments = [
            javaPath, "-cp", "/tmp/app.jar", "com.example.Runner",
            "--target", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
        ]
        let kind = ProcessScanner.classify(identity: makeIdentity(), arguments: arguments)
        #expect(kind == .userApp)
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(), kind: kind, arguments: arguments
            )
        )
    }

    @Test("main class가 부분 문자열만 일치하면 devDaemon이 아니다")
    func rejectsPartialMainClassMatch() {
        let arguments = [
            javaPath, "-cp", "/tmp/app.jar",
            "org.gradle.launcher.daemon.bootstrap.GradleDaemonWrapper"
        ]
        #expect(ProcessScanner.classify(identity: makeIdentity(), arguments: arguments) == .userApp)
    }

    @Test("알 수 없는 launcher option이 있으면 main class를 추측하지 않는다")
    func rejectsUnknownLauncherOption() {
        let arguments = [
            javaPath, "--mystery-option", "value",
            "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
        ]
        #expect(JavaMainClassParser.mainClass(from: arguments) == nil)
        #expect(ProcessScanner.classify(identity: makeIdentity(), arguments: arguments) == .userApp)
    }

    @Test("실행 파일이 java가 아니면 devDaemon이 아니다")
    func rejectsNonJavaExecutable() {
        let identity = makeIdentity(path: "/opt/homebrew/bin/kotlinc")
        #expect(ProcessScanner.classify(identity: identity, arguments: gradleArguments) == .userApp)
    }

    @Test("시스템 차단 경로는 항상 protected다")
    func classifiesSystemPathAsProtected() {
        let identity = makeIdentity(path: "/usr/libexec/secinitd")
        #expect(ProcessScanner.classify(identity: identity, arguments: []) == .protected("secinitd"))
    }

    @Test("node + MCP 엔트리포인트는 activeWorkload이고 종료 불가다")
    func classifiesMCPServer() {
        let identity = makeIdentity(path: "/opt/homebrew/bin/node")
        let arguments = ["node", "/Users/tester/mcp-servers/context7/dist/index.js"]
        let kind = ProcessScanner.classify(identity: identity, arguments: arguments)
        #expect(kind == .activeWorkload("MCP 서버"))
        #expect(
            !TerminationPolicy.canTerminate(identity: identity, kind: kind, arguments: arguments)
        )
    }

    /// 회귀 방지 핵심: argv 아무 곳의 `mcp/` 문자열로 판단하면 이 테스트가 깨진다.
    @Test("일반 앱 argv에 mcp 경로가 있어도 개발 도구로 잡지 않는다")
    func ignoresMCPStringInPlainApp() {
        let identity = makeIdentity(path: "/Applications/Notes.app/Contents/MacOS/Notes")
        let arguments = ["Notes", "--config", "/Users/tester/mcp/settings.json"]
        #expect(ProcessScanner.classify(identity: identity, arguments: arguments) == .userApp)
    }

    @Test(
        "빌드·인덱싱·런타임은 activeWorkload로 표시만 한다",
        arguments: [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/SourceKitService",
            "/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/XCBBuildService",
            "/opt/homebrew/bin/dart",
            "/Users/tester/Library/Android/sdk/emulator/emulator"
        ]
    )
    func classifiesActiveWorkloads(path: String) {
        let identity = makeIdentity(path: path)
        let kind = ProcessScanner.classify(identity: identity, arguments: [])
        guard case .activeWorkload = kind else {
            Issue.record("activeWorkload가 아님: \(kind)")
            return
        }
        #expect(!TerminationPolicy.canTerminate(identity: identity, kind: kind, arguments: []))
    }

    @Test("일반 /Applications 앱은 userApp이라 목록에서 제외된다")
    func excludesUserApps() {
        let identity = makeIdentity(path: "/Applications/Android Studio.app/Contents/MacOS/studio")
        let kind = ProcessScanner.classify(identity: identity, arguments: ["studio"])
        #expect(kind == .userApp)
        #expect(!kind.isListed)
    }
}

// MARK: - identity 재검증

@Suite("identity 재검증")
struct RevalidationTests {
    @Test("identity A와 B가 같으면 argv를 채택한다")
    func verifiesStableIdentity() {
        let identity = makeIdentity()
        let probe = ProcessScanner.Probe(
            identity: { _ in identity }, arguments: { _ in gradleArguments }
        )
        #expect(
            ProcessScanner.revalidate(matching: identity, probe: probe)
                == .verified(
                    identity: identity, arguments: gradleArguments, kind: .devDaemon(.gradle)
                )
        )
    }

    @Test("argv를 읽는 사이 identity가 바뀌면 identityChanged다")
    func detectsIdentityChangeAroundArgv() {
        let before = makeIdentity()
        let after = makeIdentity(seconds: 1_786_999_999)
        let sequence = IdentitySequence([before, after])
        let probe = ProcessScanner.Probe(
            identity: { _ in sequence.next() }, arguments: { _ in gradleArguments }
        )
        #expect(ProcessScanner.revalidate(matching: before, probe: probe) == .identityChanged)
    }

    @Test("argv를 읽지 못하면 daemonEvidenceUnavailable이다")
    func detectsMissingArgv() {
        let identity = makeIdentity()
        let probe = ProcessScanner.Probe(identity: { _ in identity }, arguments: { _ in nil })
        #expect(
            ProcessScanner.revalidate(matching: identity, probe: probe)
                == .daemonEvidenceUnavailable
        )
    }

    /// 회귀 방지 핵심: `ps`가 준 옛 PID의 행을 새 identity와 결합하면 안 된다.
    @Test("PID가 재사용돼 다른 프로세스를 가리키면 옛 argv와 결합하지 않는다")
    func rejectsReusedPID() {
        let scanned = makeIdentity()
        let reused = makeIdentity(
            path: "/Applications/Notes.app/Contents/MacOS/Notes", seconds: 1_786_999_999
        )
        let probe = ProcessScanner.Probe(
            identity: { _ in reused }, arguments: { _ in ["Notes"] }
        )
        #expect(ProcessScanner.revalidate(matching: scanned, probe: probe) == .identityChanged)
    }
}

// MARK: - 단일 종료 정책

@Suite("단일 종료 정책")
struct TerminationPolicyTests {
    @Test("검증된 Gradle 데몬만 종료 가능하다")
    func allowsVerifiedGradleDaemon() {
        #expect(
            TerminationPolicy.canTerminate(
                identity: makeIdentity(), kind: .devDaemon(.gradle), arguments: gradleArguments
            )
        )
    }

    @Test(
        "시스템 경로는 차단한다",
        arguments: [
            "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
            "/usr/libexec/secinitd",
            "/usr/sbin/distnoted",
            "/usr/bin/java",
            "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect"
        ]
    )
    func blocksProtectedPaths(path: String) {
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(path: path),
                kind: .devDaemon(.gradle),
                arguments: gradleArguments
            )
        )
    }

    @Test("보호 이름은 경로와 무관하게 차단한다")
    func blocksProtectedNames() {
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(path: "/tmp/WindowServer"),
                kind: .devDaemon(.gradle),
                arguments: gradleArguments
            )
        )
    }

    @Test("pid 1·자기 자신·부모는 차단한다")
    func blocksCriticalPIDs() {
        for pid in [Int32(1), getpid(), getppid()] {
            #expect(
                !TerminationPolicy.canTerminate(
                    identity: makeIdentity(pid: pid),
                    kind: .devDaemon(.gradle),
                    arguments: gradleArguments
                )
            )
        }
    }

    @Test("소유자가 현재 사용자가 아니면 차단한다")
    func blocksOtherUsers() {
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(uid: getuid() &+ 1),
                kind: .devDaemon(.gradle),
                arguments: gradleArguments
            )
        )
    }

    @Test("activeWorkload와 userApp은 종료할 수 없다")
    func blocksNonDaemonKinds() {
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(), kind: .activeWorkload("MCP 서버"),
                arguments: gradleArguments
            )
        )
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(), kind: .userApp, arguments: gradleArguments
            )
        )
    }

    @Test("kind는 데몬이어도 argv의 main class가 다르면 차단한다")
    func blocksMismatchedMainClass() {
        #expect(
            !TerminationPolicy.canTerminate(
                identity: makeIdentity(), kind: .devDaemon(.gradle), arguments: kotlinArguments
            )
        )
    }
}

// MARK: - 종료 절차

@Suite("종료 절차")
struct ProcessTerminatorTests {
    private func signals(
        recorder: SignalRecorder,
        revalidation: @escaping @Sendable (ProcessIdentity) -> ProcessScanner.Revalidation = {
            .verified(identity: $0, arguments: gradleArguments, kind: .devDaemon(.gradle))
        }
    ) -> ProcessTerminator.Signals {
        ProcessTerminator.Signals(
            send: { recorder.send($0, $1) },
            liveness: { recorder.liveness($0) },
            revalidate: revalidation,
            wait: { _ in }   // 실제로 기다리지 않는다.
        )
    }

    @Test("SIGTERM에 죽으면 SIGKILL을 보내지 않는다")
    func stopsAfterSIGTERM() {
        let recorder = SignalRecorder(goesAwayAfterProbe: 1)
        let outcome = ProcessTerminator.terminate(
            makeProcess(), signals: signals(recorder: recorder)
        )
        #expect(outcome == .terminated)
        #expect(recorder.sentSignals == [SIGTERM])
    }

    /// 회귀 방지 핵심: 곧바로 SIGKILL을 보내면 Gradle 락 파일이 남는다.
    @Test("끝까지 살아 있으면 SIGTERM 다음에만 SIGKILL을 보낸다")
    func escalatesToSIGKILL() {
        let recorder = SignalRecorder(goesAwayAfterProbe: nil)
        let outcome = ProcessTerminator.terminate(
            makeProcess(), gracePeriod: 0.2, signals: signals(recorder: recorder)
        )
        #expect(outcome == .killed)
        #expect(recorder.sentSignals == [SIGTERM, SIGKILL])
    }

    @Test("SIGTERM 뒤 데몬 근거가 바뀌면 SIGKILL을 보내지 않는다")
    func refusesSIGKILLAfterEvidenceChange() {
        let recorder = SignalRecorder(goesAwayAfterProbe: nil)
        let calls = IdentitySequence([makeIdentity(), nil])
        let outcome = ProcessTerminator.terminate(
            makeProcess(),
            gracePeriod: 0.2,
            signals: signals(recorder: recorder) { identity in
                // 첫 검증은 통과하고, SIGKILL 직전 재검증에서 근거가 사라진다.
                calls.next() == nil
                    ? .daemonEvidenceUnavailable
                    : .verified(
                        identity: identity, arguments: gradleArguments, kind: .devDaemon(.gradle)
                    )
            }
        )
        #expect(outcome == .refused(.daemonEvidenceChanged))
        #expect(recorder.sentSignals == [SIGTERM])
    }

    /// 회귀 방지 핵심: identity 불일치에 시그널을 보내면 남의 프로세스를 죽인다.
    @Test("identity가 스캔 결과와 다르면 어떤 시그널도 보내지 않는다")
    func refusesOnIdentityChange() {
        let recorder = SignalRecorder()
        let outcome = ProcessTerminator.terminate(
            makeProcess(),
            signals: signals(recorder: recorder) { _ in .identityChanged }
        )
        #expect(outcome == .refused(.identityChanged))
        #expect(recorder.sentSignals.isEmpty)
    }

    @Test("재검증 결과가 보호 프로세스면 거부한다")
    func refusesProtectedProcess() {
        let recorder = SignalRecorder()
        let outcome = ProcessTerminator.terminate(
            makeProcess(),
            signals: signals(recorder: recorder) { _ in
                .verified(
                    identity: makeIdentity(path: "/usr/libexec/secinitd"),
                    arguments: [], kind: .protected("secinitd")
                )
            }
        )
        #expect(outcome == .refused(.protectedProcess))
        #expect(recorder.sentSignals.isEmpty)
    }

    @Test("처음부터 없는 pid는 alreadyGone이다")
    func reportsAlreadyGone() {
        let recorder = SignalRecorder()
        let signals = ProcessTerminator.Signals(
            send: { recorder.send($0, $1) },
            liveness: { _ in .gone },
            revalidate: { _ in .identityChanged },
            wait: { _ in }
        )
        #expect(ProcessTerminator.terminate(makeProcess(), signals: signals) == .alreadyGone)
        #expect(recorder.sentSignals.isEmpty)
    }

    @Test("EPERM은 notPermitted이며 terminated로 오인하지 않는다")
    func reportsNotPermitted() {
        let recorder = SignalRecorder(permissionDenied: true)
        let outcome = ProcessTerminator.terminate(
            makeProcess(), signals: signals(recorder: recorder)
        )
        #expect(outcome == .notPermitted)
        #expect(recorder.sentSignals.isEmpty)
    }

    @Test("SIGTERM 전송 자체가 실패하면 보존한 errno를 담은 failed다")
    func reportsSignalFailure() {
        let recorder = SignalRecorder(failingSignals: [SIGTERM: EINVAL])
        let outcome = ProcessTerminator.terminate(
            makeProcess(), signals: signals(recorder: recorder)
        )
        #expect(outcome == .failed(EINVAL))
    }

    @Test("SIGTERM이 ESRCH면 이미 종료된 것으로 본다")
    func treatsESRCHAsGone() {
        let recorder = SignalRecorder(failingSignals: [SIGTERM: ESRCH])
        #expect(
            ProcessTerminator.terminate(makeProcess(), signals: signals(recorder: recorder))
                == .alreadyGone
        )
    }
}

// MARK: - 스왑 문자열 파서

@Suite("스왑 문자열 파서")
struct SwapUsageParsingTests {
    @Test("sysctl 표기에서 세 값을 바이트로 읽는다")
    func parsesStandardOutput() {
        let snapshot = MemoryInfo.parseSwapUsage(
            "total = 40960.00M  used = 39653.88M  free = 1306.12M  (encrypted)"
        )
        #expect(snapshot?.totalBytes == Int64(40960.00 * 1024 * 1024))
        #expect(snapshot?.usedBytes == Int64(39653.88 * 1024 * 1024))
        #expect(snapshot?.availableBytes == Int64(1306.12 * 1024 * 1024))
    }

    @Test("G·K 접미사와 접미사 없는 값도 읽는다")
    func parsesOtherSuffixes() {
        let snapshot = MemoryInfo.parseSwapUsage("total = 2.00G  used = 1024K  free = 512")
        let expectedTotal: Int64 = 2 * 1024 * 1024 * 1024
        let expectedUsed: Int64 = 1024 * 1024
        #expect(snapshot?.totalBytes == expectedTotal)
        #expect(snapshot?.usedBytes == expectedUsed)
        #expect(snapshot?.availableBytes == 512)
    }

    @Test("값이 하나라도 없으면 0으로 채우지 않고 nil이다")
    func rejectsIncompleteOutput() {
        #expect(MemoryInfo.parseSwapUsage("total = 40960.00M  used = 39653.88M") == nil)
        #expect(MemoryInfo.parseSwapUsage("") == nil)
        #expect(MemoryInfo.parseSwapUsage("total = ??M  used = ??M  free = ??M") == nil)
    }
}

// MARK: - 실제 시스템 지표 스모크

@Suite("메모리 지표 스모크")
struct MemoryInfoSmokeTests {
    @Test("물리 메모리 지표를 읽는다")
    func readsMemory() throws {
        let snapshot = try MemoryInfo.memory().get()
        #expect(snapshot.totalBytes > 0)
        #expect(snapshot.wiredBytes > 0)
        #expect(snapshot.freeFraction >= 0)
    }

    @Test("스왑 지표를 읽는다")
    func readsSwap() throws {
        let snapshot = try MemoryInfo.swap().get()
        #expect(snapshot.totalBytes >= 0)
        #expect(snapshot.usedBytes >= 0)
    }

    @Test("스왑 파일 크기를 읽는다")
    func readsSwapFileBytes() throws {
        #expect(try MemoryInfo.swapFileBytes().get() >= 0)
    }

    @Test("자기 프로세스의 identity와 argv를 읽는다")
    func readsOwnProcess() {
        guard case .verified(let identity, let arguments, _) =
            ProcessScanner.snapshot(pid: getpid()) else {
            Issue.record("자기 PID의 identity/argv 조회 실패")
            return
        }
        #expect(identity.pid == getpid())
        #expect(identity.uid == getuid())
        #expect(!arguments.isEmpty)
    }
}

// MARK: - 뷰모델

@Suite("메모리 뷰모델")
@MainActor
struct MemoryViewModelTests {
    private func makeViewModel(
        scanner: ProcessScanRecorder,
        terminator: TerminationRecorder = TerminationRecorder()
    ) -> MemoryViewModel {
        MemoryViewModel(
            metricsInterval: nil,
            readMemory: { .failure(.hostStatistics(1)) },
            readSwap: { .failure(.swapUsage(1)) },
            readSwapFiles: { .failure(.vmDirectory(1)) },
            scanProcesses: { scanner.scan() },
            terminate: { terminator.terminate($0) }
        )
    }

    @Test("확인창이 떠 있는 동안에는 목록을 갱신하지 않는다")
    func pausesRefreshWhileConfirming() async {
        let scanner = ProcessScanRecorder()
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.isConfirming = true
        viewModel.refreshProcesses()
        #expect(scanner.callCount == 0)

        viewModel.isConfirming = false
        viewModel.refreshProcesses()
        #expect(await waitUntil { scanner.callCount == 1 })
    }

    @Test("종료가 끝난 뒤 목록을 정확히 한 번 다시 읽는다")
    func refreshesOnceAfterTermination() async {
        let process = makeProcess()
        let scanner = ProcessScanRecorder(result: .success([process]))
        let terminator = TerminationRecorder()
        let viewModel = makeViewModel(scanner: scanner, terminator: terminator)

        viewModel.refreshProcesses()
        #expect(await waitUntil { viewModel.processes.count == 1 })

        viewModel.selectAll(true)
        #expect(viewModel.terminableSelection.count == 1)

        viewModel.terminateSelected()
        #expect(await waitUntil { !viewModel.isWorking && scanner.callCount == 2 })
        #expect(terminator.terminatedPIDs == [process.identity.pid])
        #expect(viewModel.terminationSummary != nil)
    }

    @Test("스캔이 실패하면 목록을 비우고 오류를 남긴다")
    func clearsListOnScanFailure() async {
        let scanner = ProcessScanRecorder(result: .failure(.listFailed(1)))
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.refreshProcesses()
        #expect(await waitUntil { viewModel.errorMessage != nil })
        #expect(viewModel.processes.isEmpty)
    }

    @Test("종료 불가 항목만 선택하면 시그널을 보내지 않는다")
    func ignoresNonTerminableSelection() async {
        let workload = makeProcess(
            identity: makeIdentity(path: "/opt/homebrew/bin/node"),
            arguments: ["node", "/Users/tester/mcp/server.js"],
            kind: .activeWorkload("MCP 서버")
        )
        let scanner = ProcessScanRecorder(result: .success([workload]))
        let terminator = TerminationRecorder()
        let viewModel = makeViewModel(scanner: scanner, terminator: terminator)

        viewModel.refreshProcesses()
        #expect(await waitUntil { viewModel.processes.count == 1 })

        viewModel.selectAll(true)
        #expect(viewModel.terminableSelection.isEmpty)
        viewModel.terminateSelected()
        #expect(terminator.terminatedPIDs.isEmpty)
    }

    @Test("전체 선택은 종료 가능한 항목만 고르고, 해제는 모든 항목을 푼다")
    func selectAllPicksOnlyTerminable() async {
        let daemon = makeProcess()
        let workload = makeProcess(
            identity: makeIdentity(pid: 99_992, path: "/opt/homebrew/bin/node"),
            arguments: ["node", "/Users/tester/mcp/server.js"],
            kind: .activeWorkload("MCP 서버")
        )
        let viewModel = makeViewModel(
            scanner: ProcessScanRecorder(result: .success([daemon, workload]))
        )

        viewModel.refreshProcesses()
        #expect(await waitUntil { viewModel.processes.count == 2 })

        viewModel.selectAll(true)
        // 머리글 체크박스가 "전체 선택" 상태로 보이려면 선택 수와 종료 가능 수가 같아야 한다.
        #expect(viewModel.selectedCount == 1)
        #expect(viewModel.terminableSelection.count == 1)

        viewModel.selectAll(false)
        #expect(viewModel.selectedCount == 0)
    }

    @Test("스왑 파일 안내는 임계치를 넘을 때만 띄우고, 측정 실패에는 띄우지 않는다")
    func showsSwapNoticeOnlyAboveThreshold() async {
        let failing = MemoryViewModel(
            metricsInterval: nil,
            readMemory: { .failure(.hostStatistics(1)) },
            readSwap: { .failure(.swapUsage(1)) },
            readSwapFiles: { .failure(.vmDirectory(1)) },
            scanProcesses: { .success([]) },
            terminate: { _ in .terminated }
        )
        failing.refreshMetrics()
        #expect(await waitUntil { failing.swapFileBytes != nil })
        #expect(!failing.showsSwapFileNotice)

        let noisy = MemoryViewModel(
            metricsInterval: nil,
            readMemory: { .failure(.hostStatistics(1)) },
            readSwap: { .failure(.swapUsage(1)) },
            readSwapFiles: { .success(MemoryInfo.swapFileNoticeThreshold + 1) },
            scanProcesses: { .success([]) },
            terminate: { _ in .terminated }
        )
        noisy.refreshMetrics()
        #expect(await waitUntil { noisy.showsSwapFileNotice })
    }

    @Test("실패 문구는 사유를 모아 보여 주고 성공만 있으면 nil이다")
    func buildsFailureMessage() {
        #expect(MemoryViewModel.failureMessage([.terminated, .killed]) == nil)
        let message = MemoryViewModel.failureMessage([
            .refused(.identityChanged), .refused(.identityChanged), .failed(EPERM)
        ])
        #expect(message?.contains("3개") == true)
        #expect(message?.contains("스캔 이후 다른 프로세스로 바뀜") == true)
        #expect(message?.contains("errno \(EPERM)") == true)
    }

    @Test("요약은 회수량을 약속하지 않는다")
    func summaryAvoidsReclaimPromise() {
        let summary = MemoryViewModel.summary([.terminated, .killed, .alreadyGone])
        #expect(summary?.contains("근사치") == true)
        #expect(MemoryViewModel.summary([.refused(.notTerminable)]) == nil)
    }
}

// MARK: - 시뮬레이터 일괄 종료

@Suite("시뮬레이터 일괄 종료")
@MainActor
struct SimulatorShutdownTests {
    @Test("성공하면 오류 배너 없이 끝난다")
    func shutsDownAllDevices() async {
        let viewModel = SimulatorViewModel(
            list: { [] },
            delete: { _ in true },
            erase: { _ in true },
            shutdownAll: { true }
        )

        viewModel.shutdownAll()
        #expect(await waitUntil { !viewModel.isBusy })
        #expect(viewModel.errorMessage == nil)
    }

    @Test("실패하면 오류 배너를 남긴다")
    func reportsShutdownFailure() async {
        let viewModel = SimulatorViewModel(
            list: { [] },
            delete: { _ in true },
            erase: { _ in true },
            shutdownAll: { false }
        )

        viewModel.shutdownAll()
        #expect(await waitUntil { viewModel.errorMessage != nil })
    }

    @Test("실패 문구는 성공일 때 nil이다")
    func buildsShutdownMessage() {
        #expect(SimulatorViewModel.shutdownFailureMessage(succeeded: true) == nil)
        #expect(SimulatorViewModel.shutdownFailureMessage(succeeded: false) != nil)
    }
}
