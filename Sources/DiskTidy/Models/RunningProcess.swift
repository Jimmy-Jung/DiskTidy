import Darwin
import Foundation

/// 종료 후보로 삼는 개발 데몬. 문자열 포함이 아니라 **실제 main class 일치**로만 만든다.
enum DevDaemon: String, Hashable, CaseIterable {
    case gradle
    case kotlin

    /// argv에서 파싱한 main class가 이 값과 정확히 같아야 한다.
    var mainClass: String {
        switch self {
        case .gradle: return "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
        case .kotlin: return "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"
        }
    }

    var label: String {
        switch self {
        case .gradle: return "Gradle 데몬"
        case .kotlin: return "Kotlin 컴파일 데몬"
        }
    }
}

enum ProcessKind: Hashable {
    case devDaemon(DevDaemon)             // identity-bound argv 검증 뒤에만 수동 종료 가능
    case activeWorkload(String)            // 표시만, 종료 불가
    case protected(String)                 // 표시하지 않음
    case userApp                           // 표시하지 않음

    /// 목록에 올릴지 여부. 보호 프로세스와 일반 앱은 아예 보여 주지 않는다.
    var isListed: Bool {
        switch self {
        case .devDaemon, .activeWorkload: return true
        case .protected, .userApp: return false
        }
    }

    var label: String {
        switch self {
        case .devDaemon(let daemon): return daemon.label
        case .activeWorkload(let name): return name
        case .protected(let name): return name
        case .userApp: return "사용자 앱"
        }
    }
}

/// `proc_pidinfo`가 주는 시작 시각. 초 단위로 자르면 같은 초에 재사용된 PID를
/// 같은 프로세스로 오인한다. 마이크로초까지 보존한다.
struct ProcessStartTime: Hashable {
    let seconds: Int64
    let microseconds: Int32
}

/// PID는 재사용된다. 경로·UID·시작 시각을 함께 묶어야 스캔과 종료 사이의
/// "같은 프로세스"를 판단할 수 있다.
struct ProcessIdentity: Hashable {
    let pid: Int32
    let uid: uid_t
    let startTime: ProcessStartTime
    let executablePath: String
    /// `proc_pidpath`가 돌려준 실제 경로에서만 만든 basename. argv/displayName은 쓰지 않는다.
    let executableName: String

    init(pid: Int32, uid: uid_t, startTime: ProcessStartTime, executablePath: String) {
        self.pid = pid
        self.uid = uid
        self.startTime = startTime
        self.executablePath = executablePath
        executableName = URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

/// 한 시점의 활동 지표. 전부 누적값이라 두 관찰의 **차이**로만 "지금 활동 중"을 알 수 있다.
struct ProcessUsage: Hashable {
    /// 사용자+시스템 CPU 누적 시간(초). `proc_taskinfo`의 mach 단위를 timebase로 환산한 값.
    let cpuSeconds: TimeInterval
    /// 디스크 읽기+쓰기 누적 바이트(`proc_pid_rusage`). 못 읽으면 0.
    let diskBytes: Int64
    /// 지금 이 순간 실행 중인 스레드 수. 0이 아니면 관찰 간격과 무관하게 활동 중이다.
    let runningThreads: Int
    let parentPID: Int32
    /// 부모의 실행 파일 경로. 부모가 이미 죽었으면 nil.
    let parentExecutablePath: String?
    /// 부모의 프로세스 이름(`pbi_name`). 실행 파일 이름이 버전 번호인 경우가 있어 경로만으로는 모른다 —
    /// Claude Code 네이티브 바이너리는 `~/.local/share/claude/versions/2.1.259`다(실측: "띄운 앱: 2.1.259").
    var parentProcessName: String? = nil

    /// "띄운 앱". launchd가 부모면 독립 실행(데몬이 스스로 분리한 것)이다.
    var parentDisplayName: String {
        if parentPID == 1 { return "없음 (launchd · 독립 실행)" }
        guard parentExecutablePath != nil || parentProcessName != nil else { return "부모 종료됨" }
        if let parentExecutablePath, parentExecutablePath.contains(".app/") {
            return Self.appName(forExecutablePath: parentExecutablePath)
        }
        let name = parentProcessName
            ?? parentExecutablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "?"
        return Self.agentName(name)
    }

    /// 에이전트 CLI는 실행 파일 이름보다 제품 이름이 낫다. 모르는 이름은 그대로 둔다.
    static func agentName(_ processName: String) -> String {
        switch processName {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return processName
        }
    }

    /// 헬퍼 프로세스는 이름이 길고 낯설다(`Code Helper (Plugin)`). 경로의 **첫** `.app` 이름이 사용자가
    /// 아는 앱이다 — `/Applications/Visual Studio Code.app/…/Code Helper (Plugin).app/…` → "Visual Studio Code".
    static func appName(forExecutablePath path: String) -> String {
        if let appRange = path.range(of: ".app/") {
            let prefix = path[..<appRange.lowerBound]
            if let slash = prefix.lastIndex(of: "/") { return String(prefix[prefix.index(after: slash)...]) }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// 폴링을 이어 가며 얻은 관찰 결과.
///
/// OS에 "마지막 사용" 같은 값은 없다. CPU·I/O 누적치가 마지막으로 늘어난 관찰 시각을 기억하는 것뿐이라
/// 탭이 보이는 동안만 쌓인다(뷰모델은 창 수명이라 탭을 오가도 유지된다). `ps`의 상태 문자 `I`(20초
/// 이상 유휴)는 쓰지 않는다 — 실측으로 3시간 유휴 데몬도 전부 `S`였다.
struct ProcessActivity: Hashable {
    /// 이 이하로 CPU를 쓰는 것은 활동으로 치지 않는다. 유휴 JVM도 GC·JIT 정리로 관찰 간격당 수십 ms를
    /// 쓴다(실측). 관찰 간격 대비 2%(20초에 0.4초)면 실제 작업이다.
    static let activeCPUShare = 0.02
    /// 이 이상 디스크를 읽고 썼으면 CPU를 안 써도 활동이다.
    static let activeDiskBytes: Int64 = 1_048_576

    let firstObserved: Date
    let observedAt: Date
    let usage: ProcessUsage
    /// 누적치가 마지막으로 늘었거나 실행 중 스레드가 있던 관찰 시각. nil이면 관찰 뒤 아직 변화 없음.
    let lastActive: Date?
    /// 직전 관찰 대비 활동이 있었는지.
    let isActiveNow: Bool

    /// 새 표본을 반영한다. 첫 관찰은 실행 중 스레드로만 판단한다 — 비교할 이전 값이 없다.
    static func observe(previous: ProcessActivity?, current: ProcessUsage, now: Date) -> ProcessActivity {
        var active = current.runningThreads > 0
        if let previous {
            let interval = now.timeIntervalSince(previous.observedAt)
            if interval > 0 {
                // 같은 identity의 누적치는 줄지 않는다. 음수가 보이면 표본 순서가 어긋난 것이니 0으로 본다.
                let cpuDelta = max(0, current.cpuSeconds - previous.usage.cpuSeconds)
                let diskDelta = max(0, current.diskBytes - previous.usage.diskBytes)
                if cpuDelta / interval >= activeCPUShare || diskDelta >= activeDiskBytes { active = true }
            }
        }
        return ProcessActivity(
            firstObserved: previous?.firstObserved ?? now,
            observedAt: now,
            usage: current,
            lastActive: active ? now : previous?.lastActive,
            isActiveNow: active
        )
    }

    /// "활동 중" / "유휴 12분" / "관찰 중" / "관찰 40분 동안 활동 없음".
    func statusString(now: Date) -> String {
        if isActiveNow { return "활동 중" }
        if let lastActive { return "유휴 \(DurationText.short(now.timeIntervalSince(lastActive)))" }
        let watched = now.timeIntervalSince(firstObserved)
        return watched < 60 ? "관찰 중" : "관찰 \(DurationText.short(watched)) 동안 활동 없음"
    }
}

/// 사람이 읽는 기간. 초 단위 정밀도는 여기서 필요 없다.
enum DurationText {
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "1분 미만" }
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간" : "\(days)일" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간" }
        return "\(minutes)분"
    }

    /// CPU 누적은 작은 값이 많아 초 아래도 보인다.
    static func cpu(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 { return String(format: "%.1f초", clamped) }
        let total = Int(clamped)
        if total < 3600 { return "\(total / 60)분 \(total % 60)초" }
        return "\(total / 3600)시간 \(total % 3600 / 60)분"
    }
}

struct RunningProcess: Identifiable, Hashable {
    let id: Int32                          // identity.pid
    let identity: ProcessIdentity
    let residentBytes: Int64
    let arguments: [String]                // identity A → KERN_PROCARGS2 → identity B 검증 후 값
    let displayName: String                // 표시용; 종료 정책에는 쓰지 않음
    let kind: ProcessKind
    var isSelected = false
    /// 스캔 시점 표본. 못 읽었으면 nil(표시만 빠진다).
    var usage: ProcessUsage?
    /// 뷰모델이 폴링을 이어 가며 채운다. 종료 정책과 무관한 표시 정보다.
    var activity: ProcessActivity?

    init(
        identity: ProcessIdentity,
        residentBytes: Int64,
        arguments: [String],
        displayName: String,
        kind: ProcessKind,
        usage: ProcessUsage? = nil
    ) {
        id = identity.pid
        self.identity = identity
        self.residentBytes = residentBytes
        self.arguments = arguments
        self.displayName = displayName
        self.kind = kind
        self.usage = usage
    }

    var startDate: Date {
        Date(timeIntervalSince1970:
            Double(identity.startTime.seconds) + Double(identity.startTime.microseconds) / 1_000_000)
    }

    /// "시작 09:36 (3시간 12분 전) · CPU 28.8초 · 띄운 앱: Visual Studio Code". 상태는 따로 배지로 보인다.
    func detailLine(now: Date) -> String {
        var parts = ["시작 \(Self.startText(startDate, now: now)) (\(DurationText.short(now.timeIntervalSince(startDate))) 전)"]
        if let usage {
            parts.append("CPU \(DurationText.cpu(usage.cpuSeconds))")
            parts.append("띄운 앱: \(usage.parentDisplayName)")
        }
        return parts.joined(separator: " · ")
    }

    /// 오늘 시작했으면 시각만, 아니면 날짜도. "며칠째 떠 있는 데몬"이 한눈에 보여야 한다.
    private static func startText(_ start: Date, now: Date) -> String {
        let formatter = Calendar.current.isDate(start, inSameDayAs: now) ? clockFormatter : dayClockFormatter
        return formatter.string(from: start)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var isTerminable: Bool {
        TerminationPolicy.canTerminate(
            identity: identity, kind: kind, arguments: arguments
        )
    }

    /// RSS는 근사치다. 회수량이 아니라 정렬·비교 기준으로만 쓴다.
    var residentString: String {
        ByteCountFormatter.string(fromByteCount: residentBytes, countStyle: .memory)
    }
}

/// java launcher argv에서 main class를 꺼낸다.
///
/// 실측한 Gradle 8.13 / Kotlin 2.2.21 데몬의 옵션만 허용한다. 알 수 없는 option이
/// 나오면 그 다음 토큰이 값인지 main class인지 구분할 수 없으므로 nil을 돌려준다
/// (fail-closed). 추측으로 main class를 정하면 엉뚱한 프로세스가 종료 후보가 된다.
enum JavaMainClassParser {
    /// 다음 토큰을 값으로 먹는 option. Kotlin 데몬은 `--add-exports`를 분리형으로 쓴다(실측).
    private static let optionsWithValue: Set<String> = [
        "-cp", "-classpath", "--class-path",
        "--add-opens", "--add-exports", "--add-modules", "--add-reads", "--patch-module",
        "--module-path", "-p", "--upgrade-module-path", "--limit-modules"
    ]

    /// 값을 `=`나 `:`로 같은 토큰에 붙이거나, 값이 아예 없는 option.
    /// Gradle 데몬은 `--add-opens=…`·`-javaagent:…`를, Kotlin 데몬은 `-ea`·`-XX:…`를 쓴다(실측).
    private static let selfContainedPrefixes = [
        "--class-path=", "--add-opens=", "--add-exports=", "--add-modules=",
        "--add-reads=", "--patch-module=", "--module-path=", "--upgrade-module-path=",
        "--limit-modules=", "--enable-native-access=", "--enable-preview",
        "-javaagent:", "-agentlib:", "-agentpath:", "-splash:",
        "-ea", "-da", "-enableassertions", "-disableassertions",
        "-esa", "-dsa", "-verbose", "-server", "-client",
        // `-X`가 `-Xmx4g`와 `-XX:+UseParallelGC`를 함께 덮는다.
        "-D", "-X"
    ]

    static func mainClass(from arguments: [String]) -> String? {
        var index = 1 // argv[0]은 실제 java 실행 파일
        while index < arguments.count {
            let argument = arguments[index]
            if optionsWithValue.contains(argument) {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else { return nil }
                index = valueIndex + 1
                continue
            }
            if selfContainedPrefixes.contains(where: argument.hasPrefix) {
                index += 1
                continue
            }
            // `-jar`는 main class 대신 jar를 지정한다. 데몬은 쓰지 않으므로 거부한다.
            guard !argument.hasPrefix("-") else { return nil }
            return argument
        }
        return nil
    }
}

/// UI의 `isTerminable`과 실제 시그널 전송이 **함께 통과해야 하는 단 하나의 게이트**.
/// 두 곳에 조건을 따로 구현하면 한쪽만 고쳐졌을 때 목록에 없던 프로세스가 죽는다.
enum TerminationPolicy {
    private static let protectedPathPrefixes = [
        "/System", "/usr/libexec", "/usr/sbin", "/usr/bin", "/Library/Apple"
    ]
    private static let protectedNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "ControlCenter", "coreaudiod", "DiskTidy"
    ]

    static func canTerminate(
        identity: ProcessIdentity,
        kind: ProcessKind,
        arguments: [String],
        currentUID: uid_t = getuid(),
        currentPID: Int32 = getpid(),
        parentPID: Int32 = getppid()
    ) -> Bool {
        guard case .devDaemon(let daemon) = kind,
              identity.uid == currentUID,
              identity.pid != 1,
              identity.pid != currentPID,
              identity.pid != parentPID,
              !isProtected(identity),
              identity.executableName == "java",
              JavaMainClassParser.mainClass(from: arguments) == daemon.mainClass
        else { return false }
        return true
    }

    /// 시스템 차단 경로·차단 이름 여부. 분류와 거부 사유 구분에 함께 쓴다.
    static func isProtected(_ identity: ProcessIdentity) -> Bool {
        protectedNames.contains(identity.executableName)
            || protectedPathPrefixes.contains {
                identity.executablePath == $0 || identity.executablePath.hasPrefix($0 + "/")
            }
    }
}
