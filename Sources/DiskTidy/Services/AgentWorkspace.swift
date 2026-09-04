import Darwin
import Foundation

/// 임시파일 후보의 출처. 출처를 알면 "얼마나 오래됐나" 대신 "지금 쓰는 주체가 있나"로 판정할 수 있다.
///
/// 배경: `/private/tmp`의 대부분이 Claude Code·Codex가 남긴 작업물이 됐다(실측 2026-09-03:
/// Codex DerivedData 1.5GB, Claude 세션 스크래치 0.6GB). 이것들은 오늘 만들어졌어도 세션이 끝났거나
/// 빌드가 멈추면 쓸모가 없는데, "3일 미접근" 규칙으로는 영영 후보가 되지 않았다.
enum TempCandidateKind: Hashable, Sendable {
    /// `/private/tmp/claude-<uid>/<프로젝트>/<세션 UUID>`. Claude Code 세션 하나의 스크래치·백그라운드 작업 출력.
    case claudeSession(id: String)
    /// tmp에 놓인 DerivedData. `/private/tmp/codex-dd-*`처럼 이름이 말해 주는 것과, 에이전트가
    /// `mktemp -d /tmp/<프로젝트>-derived.XXXXXX`로 만든 임의 이름 디렉터리 둘 다 — 후자는 이름이 아니라
    /// **모양**(`info.plist` + `Build/`)으로 알아본다(실측: 4개 670MB가 "기타"로 묻혀 있었다). 재빌드로 복구된다.
    case codexDerivedData
    /// 에이전트가 남긴 부속 파일. `$TMPDIR/.com.openai.codex.*`, `codex-*.log`, SPM lock,
    /// `claude-context-bucket-<세션>` 등. Claude 세션에 딸린 것은 그 세션 id를 든다.
    case agentArtifact(claudeSessionID: String?)
    /// 출처를 모른다. 보수적 규칙(보존 기간 동안 읽지도 쓰지도 않음)으로만 판정한다.
    case other

    var group: TempCandidateGroup {
        switch self {
        case .claudeSession: return .claudeSession
        case .codexDerivedData: return .codexDerivedData
        case .agentArtifact: return .agentArtifact
        case .other: return .other
        }
    }

    /// 규칙 3의 형태. 에이전트 작업물은 정지 기간(mtime만), 나머지는 보존 기간(mtime·atime 둘 다).
    var ageRule: TempScanner.AgeRule {
        switch self {
        case .claudeSession, .codexDerivedData, .agentArtifact:
            return .quiet(seconds: AgentWorkspace.quietPeriodSeconds)
        case .other:
            return .days(TempScanner.defaultMinimumAgeDays)
        }
    }

    /// 후보로 올라온 근거. 규칙이 **보장하는 사실만** 적는다 — 측정값을 적으면 화면과 어긋난다.
    var evidence: String {
        let quiet = "\(AgentWorkspace.quietPeriodSeconds / 60)분 넘게 변경 없음 · 열린 파일 없음"
        switch self {
        case .claudeSession: return "세션 종료 · " + quiet
        case .codexDerivedData: return "빌드 프로세스 없음 · " + quiet
        case .agentArtifact(let sessionID): return (sessionID == nil ? "" : "세션 종료 · ") + quiet
        case .other: return "\(TempScanner.defaultMinimumAgeDays * 24)시간 넘게 읽지도 쓰지도 않음 · 열린 파일 없음"
        }
    }
}

/// 화면 그룹. `claudeSession`은 세션마다 값이 달라 kind로는 묶이지 않는다.
enum TempCandidateGroup: Int, CaseIterable, Hashable, Sendable {
    case claudeSession
    case codexDerivedData
    case agentArtifact
    case other

    var label: String {
        switch self {
        case .claudeSession: return "Claude 세션 스크래치"
        case .codexDerivedData: return "빌드 산출물 (DerivedData)"
        case .agentArtifact: return "에이전트 잡파일"
        case .other: return "기타"
        }
    }
}

enum AgentWorkspace {
    /// 에이전트 작업물의 정지 기간. 마지막 쓰기 뒤 이만큼 조용하면 작업이 끝난 것으로 본다.
    /// 빌드 사이·턴 사이에 파일이 잠깐 안 열려 있는 순간을 넘기기 위한 여유다. Claude·Codex 공통 30분.
    static let quietPeriodSeconds: Int64 = 30 * 60

    /// Claude Code가 세션 스크래치를 두는 루트 이름. `/private/tmp/claude-<uid>/<프로젝트 슬러그>/<세션 UUID>/`.
    /// 이 디렉터리는 통째로 후보가 되지 않고, 스캐너가 세션 디렉터리 단위로 내려간다.
    static var claudeRootName: String { "claude-\(getuid())" }

    static func isSessionID(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    /// 최상위 엔트리의 출처. Claude 루트는 여기 오지 않는다(스캐너가 먼저 처리한다).
    /// `path`를 주면 이름이 임의인 DerivedData(`mktemp`로 만든 것)도 모양으로 알아본다.
    static func classify(name: String, isDirectory: Bool, path: String? = nil) -> TempCandidateKind {
        if isDirectory {
            if name.hasPrefix("codex-dd-") { return .codexDerivedData }
            if let path, looksLikeDerivedData(path) { return .codexDerivedData }
            return .other
        }
        if let sessionID = claudeSessionID(inArtifactName: name) {
            return .agentArtifact(claudeSessionID: sessionID)
        }
        if name.hasPrefix(".com.openai.codex.") { return .agentArtifact(claudeSessionID: nil) }
        if name.hasPrefix("codex-"), name.hasSuffix(".log") { return .agentArtifact(claudeSessionID: nil) }
        // SPM이 DerivedData 경로를 이름에 박아 만드는 0바이트 lock 파일.
        // `_private_tmp_codex-dd-<이름>_SourcePackages_Package.resolved.lock`
        if name.hasPrefix("_"), name.contains("codex-dd-"), name.hasSuffix(".lock") {
            return .agentArtifact(claudeSessionID: nil)
        }
        return .other
    }

    /// Xcode DerivedData는 어디에 만들어도 루트에 `info.plist`(WorkspacePath)와 `Build/`를 둔다.
    /// 둘 다 있어야 한다 — 하나만 보면 사용자가 손으로 만든 폴더를 빌드 산출물로 오인한다.
    static func looksLikeDerivedData(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + "/info.plist")
            && FileManager.default.fileExists(atPath: path + "/Build", isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// `claude-context-bucket-<세션>`·`claude-tool-count-<세션>`에서 세션 id.
    static func claudeSessionID(inArtifactName name: String) -> String? {
        for prefix in ["claude-context-bucket-", "claude-tool-count-"] where name.hasPrefix(prefix) {
            let id = String(name.dropFirst(prefix.count))
            return isSessionID(id) ? id : nil
        }
        return nil
    }

    /// 목록에 보일 이름. 슬러그는 `-Users-<사용자>-Documents-GitHub-DiskTidy` 꼴이라 홈 앞부분을 떼고,
    /// 세션은 앞 8자만 쓴다. 전체 경로는 ⓘ 팝오버에 있다.
    static func claudeSessionDisplayName(project: String, sessionID: String) -> String {
        let homePrefix = "-Users-\(NSUserName())-"
        let trimmed = project.hasPrefix(homePrefix) ? String(project.dropFirst(homePrefix.count)) : project
        return "\(trimmed) · \(sessionID.prefix(8))"
    }

    /// 사용 중 경고 이유. nil이면 규칙 판정으로 넘어간다.
    static func blockingReason(
        for kind: TempCandidateKind, path: String, live: LiveAgentState
    ) -> String? {
        switch kind {
        case .claudeSession(let id):
            // 경로는 `claude-<uid>/<슬러그>/<세션>`. 슬러그로 트랜스크립트와 프로세스를 대조한다.
            let slug = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            return live.claudeSessionBlockingReason(sessionID: id, projectSlug: slug)
        case .agentArtifact(claudeSessionID: .some(let id)):
            return live.claudeSessionBlockingReason(sessionID: id, projectSlug: nil)
        case .codexDerivedData:
            return live.references(path) ? "사용 중 — 빌드 프로세스가 이 경로를 쓰고 있음" : nil
        case .agentArtifact(claudeSessionID: .none), .other:
            return nil
        }
    }
}

/// 지금 살아 있는 에이전트 상태. 스캔 시점과 삭제 직전에 각각 찍어 그 스냅샷으로 판정한다.
struct LiveAgentState: Sendable {
    /// 살아 있는 Claude Code 프로세스 하나. `~/.claude/sessions/<pid>.json` 한 건.
    struct ClaudeProcess: Hashable, Sendable {
        let pid: Int32
        /// **프로세스가 처음 만든** 세션. `/resume`으로 다른 세션을 이어 써도 갱신되지 않는다(실측) —
        /// 그래서 이 값만으로 "세션 종료"를 단정하지 않는다. `claudeSessionBlockingReason` 참고.
        let sessionID: String
        let cwd: String
        let startedAt: Date
    }

    let claudeProcesses: [ClaudeProcess]
    /// 사용자 프로세스의 명령줄. nil은 "읽지 못했다" — 그때는 참조 여부를 알 수 없으므로 사용 중으로 본다.
    let processArguments: [String]?
    /// `~/.claude/projects`. 세션의 트랜스크립트(`<슬러그>/<세션>.jsonl`)가 여기 있다.
    let projectsDirectory: URL
    let now: Date

    init(
        claudeProcesses: [ClaudeProcess],
        processArguments: [String]?,
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        now: Date = Date()
    ) {
        self.claudeProcesses = claudeProcesses
        self.processArguments = processArguments
        self.projectsDirectory = projectsDirectory
        self.now = now
    }

    static func current() -> LiveAgentState {
        LiveAgentState(claudeProcesses: liveClaudeProcesses(), processArguments: processArguments())
    }

    /// 프로세스가 처음 만든 세션 id → pid. 같은 세션을 두 프로세스가 `--resume`으로 열면 id가 겹친다 —
    /// 여기서는 "살아 있다"만 필요하므로 어느 pid를 남기든 판정은 같다.
    var claudeSessions: [String: Int32] {
        Dictionary(claudeProcesses.map { ($0.sessionID, $0.pid) }, uniquingKeysWith: { first, _ in first })
    }

    func claudePID(forSession id: String) -> Int32? {
        claudeSessions[id]
    }

    /// Claude 세션이 살아 있을 가능성이 있으면 그 사유, 없으면 nil. 세 신호 중 하나면 사용 중이다.
    ///
    /// 1. 살아 있는 프로세스가 처음 만든 세션이다.
    /// 2. 트랜스크립트가 정지 기간 안에 갱신됐다 — 어느 프로세스인지 몰라도 대화가 이어지는 중이다.
    /// 3. 같은 프로젝트에서 **그 트랜스크립트가 마지막으로 쓰이기 전에 시작한** Claude 프로세스가 살아 있다 —
    ///    그 프로세스가 `/resume`으로 이 세션을 이어 쓰고 있을 수 있다. 실측: pid 89943의 json은 세션
    ///    15856e44인데 실제로는 27ac3ee3의 트랜스크립트를 12:03에 쓰고 있었다.
    ///
    /// 세션이 끝난 뒤 시작한 프로세스는 3에 걸리지 않는다. 그 세션을 재개했다면 트랜스크립트가 다시 쓰여
    /// 2나 3에 걸리게 된다. 재개만 하고 아직 한 마디도 안 한 세션은 잡지 못한다 — 그때 남는 것은
    /// 재개 시점에 hook이 다시 만든 빈 스크래치이고, 정지 기간 30분이 그 직후를 덮는다.
    func claudeSessionBlockingReason(sessionID: String, projectSlug: String?) -> String? {
        if let pid = claudePID(forSession: sessionID) {
            return "사용 중 — Claude 세션 실행 중 (PID \(pid))"
        }
        guard let transcript = transcript(sessionID: sessionID, projectSlug: projectSlug) else { return nil }

        let idle = now.timeIntervalSince(transcript.modifiedAt)
        let lastTalk = "마지막 대화 \(Self.clockFormatter.string(from: transcript.modifiedAt))"
        if idle < TimeInterval(AgentWorkspace.quietPeriodSeconds) {
            return "사용 중 — \(max(1, Int(idle / 60)))분 전까지 대화가 이어짐 · \(lastTalk)"
        }
        // json의 startedAt은 밀리초, 파일 mtime은 나노초다. 경계에서 어긋나 놓치는 쪽이 위험하므로
        // 1분 여유를 두고 "먼저 시작했다"로 본다 — 더 많은 프로세스를 재개 후보로 치는 방향(fail-closed).
        if let process = claudeProcesses.first(where: {
            $0.startedAt.addingTimeInterval(-60) <= transcript.modifiedAt
                && Self.slugMatches(cwd: $0.cwd, slug: transcript.projectSlug)
        }) {
            return "사용 중 — 같은 프로젝트의 Claude 세션(PID \(process.pid))이 이어 쓰고 있을 수 있음 · \(lastTalk)"
        }
        return nil
    }

    /// 사유 문구에 붙는 시각. 행의 "수정" 시각(디렉터리 mtime)과 달리 대화가 실제로 이어진 시점이다.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 트랜스크립트 파일. 슬러그를 모르면(잡파일) 프로젝트 디렉터리 전부에서 찾는다.
    private func transcript(sessionID: String, projectSlug: String?) -> (projectSlug: String, modifiedAt: Date)? {
        let slugs: [String]
        if let projectSlug {
            slugs = [projectSlug]
        } else {
            slugs = (try? FileManager.default.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        }
        for slug in slugs {
            let url = projectsDirectory.appendingPathComponent(slug).appendingPathComponent("\(sessionID).jsonl")
            if let modified = FileAttributes.modificationDate(of: url) {
                return (slug, modified)
            }
        }
        return nil
    }

    /// 프로젝트 슬러그(`-Users-jimmy-Documents-GitHub-DiskTidy`)는 cwd의 구분자·특수문자를 `-`로 바꾼 것이다.
    /// 어떤 문자가 바뀌는지에 기대지 않고 영숫자만 남겨 비교한다. 대소문자는 그대로 둔다 —
    /// APFS는 대소문자를 구분하지 않아 같은 폴더가 다른 표기로 열릴 수 있으므로 소문자로 맞춘다.
    static func slugMatches(cwd: String, slug: String) -> Bool {
        func key(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let cwdKey = key(cwd)
        return !cwdKey.isEmpty && cwdKey == key(slug)
    }

    /// 어떤 프로세스든 명령줄에 이 경로를 들고 있으면 사용 중이다(`xcodebuild -derivedDataPath …`).
    /// `/private/tmp`과 `/tmp` 두 표기를 다 본다 — 도구마다 다르게 적는다.
    func references(_ path: String) -> Bool {
        // 빈 목록도 "알 수 없음"이다. 살아 있는 시스템에 사용자 프로세스가 0개일 수는 없다.
        guard let processArguments, !processArguments.isEmpty else { return true }
        var spellings = [path]
        if path.hasPrefix("/private/") { spellings.append(String(path.dropFirst("/private".count))) }
        return processArguments.contains { line in
            spellings.contains { Self.mentionsPath(line, $0) }
        }
    }

    /// 경로가 명령줄에 **그 경로로** 들어 있는지. 뒤에 `/`·공백·따옴표·끝이 와야 한다 —
    /// 단순 포함 검사는 `codex-dd-x`를 `codex-dd-xyz`의 빌드에도 걸리게 해 멀쩡한 후보를 막는다
    /// (실측: `…-red`와 `…-red-fresh`가 같이 있다).
    static func mentionsPath(_ line: String, _ path: String) -> Bool {
        var searchRange = line.startIndex..<line.endIndex
        while let range = line.range(of: path, range: searchRange) {
            if range.upperBound == line.endIndex { return true }
            let next = line[range.upperBound]
            if next == "/" || next.isWhitespace || next == "\"" || next == "'" { return true }
            searchRange = range.upperBound..<line.endIndex
        }
        return false
    }

    /// Claude Code는 실행 중인 세션마다 `~/.claude/sessions/<pid>.json`(`pid`, `sessionId`, `cwd`, `startedAt`)을 둔다.
    /// 비정상 종료 뒤 남은 파일이 있을 수 있어 pid가 살아 있는지 확인한 것만 취한다.
    /// `startedAt`이 없으면 아주 옛날에 시작한 것으로 본다 — 그래야 어느 세션이든 재개했을 수 있다고 보게 된다(fail-closed).
    static func liveClaudeProcesses(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions"),
        isAlive: (Int32) -> Bool = processExists
    ) -> [ClaudeProcess] {
        var processes: [ClaudeProcess] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value,
                  let sessionID = object["sessionId"] as? String,
                  isAlive(pid) else { continue }
            let startedAt = (object["startedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            processes.append(ClaudeProcess(
                pid: pid, sessionID: sessionID, cwd: object["cwd"] as? String ?? "", startedAt: startedAt
            ))
        }
        return processes
    }

    /// `kill(pid, 0)`은 시그널을 보내지 않고 존재만 확인한다. 권한이 없어 `EPERM`이어도 살아 있는 것이다.
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// 사용자 프로세스 전체의 명령줄. 우리 자식(`du`, `lsof`)은 뺀다 — 인자에 후보 경로가 들어 있다.
    /// 실패하면 nil. 빈 배열로 돌려주면 "참조 없음"과 구분되지 않는다.
    static func processArguments() -> [String]? {
        let result = ShellRunner.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
        guard result.succeeded else { return nil }
        let me = getpid()
        return result.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else {
                return nil
            }
            guard pid != me, ppid != me else { return nil }
            return String(fields[2])
        }
    }
}
