import Darwin
import Foundation

/// 사용자 소유 프로세스를 열거하고 분류한다.
///
/// `/bin/ps`는 **후보 PID와 RSS만** 찾는 용도다. argv·소유자·실행 경로는 `ps` 출력에서
/// 가져오지 않는다. `ps`가 결과를 돌려준 직후에도 PID는 재사용될 수 있으므로,
/// 옛 argv와 새 identity를 한 `RunningProcess`에 섞으면 엉뚱한 프로세스가
/// 종료 후보가 된다. 모든 판단 근거는 identity A → argv → identity B 순서로 다시 읽는다.
enum ProcessScanner {
    enum Error: Swift.Error, Equatable {
        case listFailed(Int32)
        case malformedOutput
    }

    enum Revalidation: Equatable {
        case verified(identity: ProcessIdentity, arguments: [String], kind: ProcessKind)
        case identityChanged
        case daemonEvidenceUnavailable
    }

    /// Darwin proc API 대역. 기본값이 곧 production 동작이며,
    /// 테스트는 실제 프로세스 없이 PID 재사용·argv 변조 상황을 재현한다.
    struct Probe {
        var identity: @Sendable (Int32) -> ProcessIdentity?
        var arguments: @Sendable (Int32) -> [String]?
        /// 활동 지표. 표시 전용이라 못 읽어도 스캔은 계속한다.
        var usage: @Sendable (Int32) -> ProcessUsage? = { systemUsage($0) }

        static let system = Probe(
            identity: { systemIdentity($0) },
            arguments: { systemArguments($0) }
        )
    }

    /// `KERN_PROCARGS2` 버퍼 상한. ARG_MAX보다 넉넉하되 무한 할당은 막는다.
    private static let maximumArgumentBytes = 8 * 1024 * 1024
    private static let maximumArgumentCount = 4096

    // MARK: - 스캔

    static func scan(probe: Probe = .system) -> Result<[RunningProcess], Error> {
        let result = ShellRunner.run("/bin/ps", ["-U", String(getuid()), "-o", "pid=,rss="])
        guard result.succeeded else { return .failure(.listFailed(result.exitCode)) }

        let rows: [(pid: Int32, residentKB: Int64)]
        do {
            rows = try parseProcessList(result.output)
        } catch let error as Error {
            return .failure(error)
        } catch {
            return .failure(.malformedOutput)
        }

        let processes = rows.compactMap { row -> RunningProcess? in
            // identity를 다시 읽지 못하거나 그 사이 PID가 재사용됐으면 후보에서 뺀다.
            guard case .verified(let identity, let arguments, let kind) =
                snapshot(pid: row.pid, probe: probe), kind.isListed else { return nil }
            return RunningProcess(
                identity: identity,
                residentBytes: row.residentKB * 1024,
                arguments: arguments,
                displayName: identity.executableName,
                kind: kind,
                usage: probe.usage(row.pid)
            )
        }
        return .success(processes.sorted { $0.residentBytes > $1.residentBytes })
    }

    /// 목록에 있는 프로세스의 활동 지표만 다시 읽는다(5초마다). `ps`를 다시 돌리지 않는다.
    /// PID가 그 사이 재사용됐으면 nil — 다른 프로세스의 CPU를 이 데몬의 활동으로 적으면 안 된다.
    static func sampleUsage(of identity: ProcessIdentity, probe: Probe = .system) -> ProcessUsage? {
        guard probe.identity(identity.pid) == identity else { return nil }
        return probe.usage(identity.pid)
    }

    /// `/bin/ps -o pid=,rss=` 출력. `rss`는 KB 단위다.
    ///
    /// 숫자가 하나도 없는 줄은 빈 줄이나 헤더 잔여물로 보고 넘긴다. 그 외의 줄은
    /// **엄격히 두 개의 음이 아닌 정수**여야 한다. 애매한 줄을 조용히 버리면
    /// 목록이 부분적으로 비는데 UI에는 "정리할 게 없음"으로 보인다.
    static func parseProcessList(_ output: String) throws -> [(pid: Int32, residentKB: Int64)] {
        var rows: [(pid: Int32, residentKB: Int64)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.contains(where: { $0.contains(where: \.isNumber) }) else { continue }
            guard fields.count == 2,
                  let pid = Int32(fields[0]), pid > 0,
                  let residentKB = Int64(fields[1]), residentKB >= 0 else {
                throw Error.malformedOutput
            }
            rows.append((pid, residentKB))
        }
        return rows
    }

    // MARK: - identity-bound argv

    /// identity A → `KERN_PROCARGS2` → identity B. A == B일 때만 argv를 채택한다.
    static func snapshot(pid: Int32, probe: Probe = .system) -> Revalidation {
        guard let before = probe.identity(pid) else { return .identityChanged }
        guard let arguments = probe.arguments(pid) else { return .daemonEvidenceUnavailable }
        guard let after = probe.identity(pid), before == after else { return .identityChanged }
        return .verified(
            identity: before,
            arguments: arguments,
            kind: classify(identity: before, arguments: arguments)
        )
    }

    /// 스캔 시점 identity와 같은 프로세스인지 다시 확인한다.
    /// 종료기는 scan-time argv를 믿지 않고 이 결과만 쓴다.
    static func revalidate(
        matching expected: ProcessIdentity, probe: Probe = .system
    ) -> Revalidation {
        switch snapshot(pid: expected.pid, probe: probe) {
        case .verified(let identity, let arguments, let kind):
            guard identity == expected else { return .identityChanged }
            return .verified(identity: identity, arguments: arguments, kind: kind)
        case .identityChanged:
            return .identityChanged
        case .daemonEvidenceUnavailable:
            return .daemonEvidenceUnavailable
        }
    }

    // MARK: - 분류

    /// 실제 실행 경로가 시스템 차단 경로면 항상 `.protected`다. `.devDaemon`은
    /// 실행 파일명이 `java`이고 argv에서 파싱한 **실제 main class**가 정확히 일치할 때만 만든다.
    static func classify(identity: ProcessIdentity, arguments: [String]) -> ProcessKind {
        if TerminationPolicy.isProtected(identity) {
            return .protected(identity.executableName)
        }
        if identity.executableName == "java",
           let mainClass = JavaMainClassParser.mainClass(from: arguments),
           let daemon = DevDaemon.allCases.first(where: { $0.mainClass == mainClass }) {
            return .devDaemon(daemon)
        }
        if identity.executableName == "node", isMCPServerEntryPoint(arguments) {
            return .activeWorkload("MCP 서버")
        }
        if let label = activeWorkloadLabel(for: identity, arguments: arguments) {
            return .activeWorkload(label)
        }
        return .userApp
    }

    /// node의 **스크립트 인자**에서만 MCP 여부를 본다. argv 아무 곳의 `mcp/` 문자열로
    /// 판단하면 설정 경로에 `mcp`가 든 일반 앱까지 개발 도구로 잡힌다.
    private static func isMCPServerEntryPoint(_ arguments: [String]) -> Bool {
        guard let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            return false
        }
        return script.split(separator: "/").contains { $0.lowercased().contains("mcp") }
    }

    /// 상태만 보여 주고 이 탭에서는 종료하지 않는 작업들.
    ///
    /// `dart`는 하위 명령이 정체다. 한 머신에 `dart` 열댓 개가 뜨는데 대부분 에이전트 세션마다 하나씩
    /// 붙는 `dart mcp-server`고, 나머지는 VS Code Dart 확장의 분석 서버·도구 데몬이다(실측).
    /// 전부 "Dart/Flutter"로 뭉치면 사용자는 자기가 안 하는 Flutter 작업이 도는 줄 안다.
    static func activeWorkloadLabel(for identity: ProcessIdentity, arguments: [String]) -> String? {
        if identity.executablePath.contains("/CoreSimulator/") {
            return "시뮬레이터 런타임"
        }
        switch identity.executableName {
        case "SourceKitService", "sourcekit-lsp", "swift-frontend", "swift-driver":
            return "Swift 인덱싱/빌드"
        // Xcode 앱 본체는 빌드 작업이 아니라 에디터다. 목록에 넣으면 노이즈만 는다.
        case "XCBBuildService", "xcodebuild":
            return "Xcode 빌드"
        case "dart":
            return dartLabel(arguments: arguments)
        case "dartvm":
            return "Dart VM"
        case "flutter", "flutter_tools":
            return "Flutter 도구"
        // adb는 에뮬레이터가 아니라 기기·에뮬레이터와 통신하는 서버다. Flutter 도구가 기기 검색을 위해
        // 한 번 띄우면 분리돼 상주한다.
        case "adb":
            return "adb 서버 (Android 디버그 브리지)"
        case "qemu-system-aarch64", "qemu-system-x86_64", "emulator":
            return "Android 에뮬레이터"
        default:
            return nil
        }
    }

    /// `dart <하위 명령> …`. 첫 비옵션 인자가 하위 명령이다.
    private static func dartLabel(arguments: [String]) -> String {
        let subcommand = arguments.dropFirst().first { !$0.hasPrefix("-") } ?? ""
        switch subcommand {
        case "mcp-server": return "MCP 서버"
        case "language-server", "analysis_server": return "Dart 분석 서버"
        case "tooling-daemon": return "Dart 도구 데몬"
        case "devtools": return "Dart DevTools"
        case "run", "": return "Dart/Flutter"
        default: return "Dart \(subcommand)"
        }
    }

    // MARK: - Darwin proc API

    private static func systemIdentity(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
            return nil
        }

        // Swift importer가 `PROC_PIDPATHINFO_MAXSIZE` 매크로를 노출하지 않는다.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard path.hasPrefix("/") else { return nil }

        return ProcessIdentity(
            pid: pid,
            uid: info.pbi_uid,
            startTime: ProcessStartTime(
                seconds: Int64(bitPattern: info.pbi_start_tvsec),
                // 값이 깨져도 트랩 대신 그대로 보존한다. identity 비교만 하면 되기 때문이다.
                microseconds: Int32(truncatingIfNeeded: info.pbi_start_tvusec)
            ),
            executablePath: path
        )
    }

    /// `proc_taskinfo`(CPU 누적·실행 중 스레드) + `proc_pid_rusage`(디스크 I/O) + 부모 pid.
    /// 시간 값은 mach 절대 시간 단위라 timebase로 초로 바꾼다 — Apple Silicon에서는 ns가 아니다(125/3).
    private static func systemUsage(_ pid: Int32) -> ProcessUsage? {
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }

        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        var rusage = rusage_info_v4()
        let hasRusage = withUnsafeMutablePointer(to: &rusage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        let diskBytes = hasRusage
            ? Int64(clamping: rusage.ri_diskio_bytesread &+ rusage.ri_diskio_byteswritten)
            : 0

        let parentPID = Int32(bitPattern: bsd.pbi_ppid)
        return ProcessUsage(
            cpuSeconds: machSeconds(task.pti_total_user &+ task.pti_total_system),
            diskBytes: diskBytes,
            runningThreads: Int(task.pti_numrunning),
            parentPID: parentPID,
            parentExecutablePath: executablePath(of: parentPID),
            parentProcessName: processName(of: parentPID)
        )
    }

    /// `pbi_name`(긴 이름), 비어 있으면 `pbi_comm`(16자). 둘 다 고정 길이 C 문자열 튜플이다.
    private static func processName(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // 튜플을 지역 상수로 복사한다. `&info.pbi_name`을 넘기면서 클로저 안에서 `info`를 읽으면
        // 배타 접근 위반이다.
        let nameTuple = info.pbi_name
        let name = withUnsafePointer(to: nameTuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: nameTuple)) {
                String(cString: $0)
            }
        }
        if !name.isEmpty { return name }
        let commTuple = info.pbi_comm
        let comm = withUnsafePointer(to: commTuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: commTuple)) {
                String(cString: $0)
            }
        }
        return comm.isEmpty ? nil : comm
    }

    private static let machTimebase: (numerator: Double, denominator: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(max(info.denom, 1)))
    }()

    static func machSeconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks) * machTimebase.numerator / machTimebase.denominator / 1_000_000_000
    }

    private static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // Swift importer가 `PROC_PIDPATHINFO_MAXSIZE` 매크로를 노출하지 않는다.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/") ? path : nil
    }

    private static func systemArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > 0, size <= maximumArgumentBytes else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0, size <= buffer.count else {
            return nil
        }
        return parseProcArgs(Data(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` 버퍼: `Int32 argc` + 실행 경로 + NUL 패딩 + argc개 NUL 종료 문자열.
    /// argc 경계·종결 NUL·UTF-8 중 하나라도 어긋나면 nil이다. 부분 파싱 결과를 쓰면
    /// main class가 없는 argv를 "옵션만 있는 데몬"으로 오인한다.
    static func parseProcArgs(_ data: Data) -> [String]? {
        let bytes = [UInt8](data)
        let headerSize = MemoryLayout<Int32>.size
        guard bytes.count > headerSize else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes[0 ..< headerSize]) }
        guard argc > 0, argc <= maximumArgumentCount else { return nil }

        var index = headerSize
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // 실행 경로
        guard index < bytes.count else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // 정렬용 NUL 패딩

        var arguments: [String] = []
        while arguments.count < Int(argc) {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return nil }             // 종결 NUL 없음 = 잘림
            guard let value = String(bytes: bytes[start ..< index], encoding: .utf8) else {
                return nil
            }
            arguments.append(value)
            index += 1
        }
        return arguments
    }
}
