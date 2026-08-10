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

struct RunningProcess: Identifiable, Hashable {
    let id: Int32                          // identity.pid
    let identity: ProcessIdentity
    let residentBytes: Int64
    let arguments: [String]                // identity A → KERN_PROCARGS2 → identity B 검증 후 값
    let displayName: String                // 표시용; 종료 정책에는 쓰지 않음
    let kind: ProcessKind
    var isSelected = false

    init(
        identity: ProcessIdentity,
        residentBytes: Int64,
        arguments: [String],
        displayName: String,
        kind: ProcessKind
    ) {
        id = identity.pid
        self.identity = identity
        self.residentBytes = residentBytes
        self.arguments = arguments
        self.displayName = displayName
        self.kind = kind
    }

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
