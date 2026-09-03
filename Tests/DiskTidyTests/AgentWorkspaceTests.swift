import Darwin
import Foundation
import Testing

@testable import DiskTidy

// MARK: - 출처 분류 (순수 함수)

@Suite("에이전트 작업물 분류")
struct AgentWorkspaceClassificationTests {
    @Test("codex-dd- 디렉터리는 Codex 빌드 산출물, 같은 이름의 파일은 기타다")
    func classifiesCodexDerivedData() {
        #expect(AgentWorkspace.classify(name: "codex-dd-agenttrace-category", isDirectory: true) == .codexDerivedData)
        #expect(AgentWorkspace.classify(name: "codex-dd-agenttrace-category", isDirectory: false) == .other)
    }

    @Test("에이전트 잡파일 이름을 알아본다")
    func classifiesArtifacts() {
        #expect(AgentWorkspace.classify(name: ".com.openai.codex.p4TS6M", isDirectory: false) == .agentArtifact(claudeSessionID: nil))
        #expect(AgentWorkspace.classify(name: "codex-agenttrace-category-red.log", isDirectory: false) == .agentArtifact(claudeSessionID: nil))
        #expect(AgentWorkspace.classify(
            name: "_private_tmp_codex-dd-x_SourcePackages_Package.resolved.lock", isDirectory: false
        ) == .agentArtifact(claudeSessionID: nil))
        let session = "8c5a9089-8c56-43a3-b7ea-c24aed83fbc8"
        #expect(AgentWorkspace.classify(name: "claude-context-bucket-\(session)", isDirectory: false)
            == .agentArtifact(claudeSessionID: session))
        #expect(AgentWorkspace.classify(name: "claude-tool-count-\(session)", isDirectory: false)
            == .agentArtifact(claudeSessionID: session))
    }

    @Test("이름이 임의여도 info.plist와 Build가 있으면 DerivedData다")
    func recognizesDerivedDataByShape() throws {
        let temp = try TempDirectory()
        let derived = temp.url.appendingPathComponent("agentchatkit-demo-derived.gRSKu8")
        try FileManager.default.createDirectory(at: derived.appendingPathComponent("Build"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: derived.appendingPathComponent("info.plist"))
        #expect(AgentWorkspace.classify(name: derived.lastPathComponent, isDirectory: true, path: derived.path) == .codexDerivedData)

        // 하나만 있으면 아니다 — 사용자가 손으로 만든 Build 폴더일 수 있다.
        let half = temp.url.appendingPathComponent("just-build")
        try FileManager.default.createDirectory(at: half.appendingPathComponent("Build"), withIntermediateDirectories: true)
        #expect(AgentWorkspace.classify(name: "just-build", isDirectory: true, path: half.path) == .other)
        // Build가 파일이면 아니다.
        let fake = temp.url.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data().write(to: fake.appendingPathComponent("info.plist"))
        try Data().write(to: fake.appendingPathComponent("Build"))
        #expect(AgentWorkspace.classify(name: "fake", isDirectory: true, path: fake.path) == .other)
    }

    @Test("모르는 이름은 기타다")
    func classifiesUnknownAsOther() {
        #expect(AgentWorkspace.classify(name: "hsperfdata_jimmy", isDirectory: true) == .other)
        #expect(AgentWorkspace.classify(name: "codex-notes.txt", isDirectory: false) == .other)
        #expect(AgentWorkspace.classify(name: "claude-context-bucket-not-a-uuid", isDirectory: false) == .other)
    }

    @Test("세션 id는 UUID 형태만 인정한다")
    func recognizesSessionIDs() {
        #expect(AgentWorkspace.isSessionID("27ac3ee3-3872-45d9-984d-db142fbd18d5"))
        #expect(!AgentWorkspace.isSessionID("scratchpad"))
        #expect(!AgentWorkspace.isSessionID(""))
    }

    @Test("표시 이름은 홈 앞부분을 떼고 세션 앞 8자만 쓴다")
    func buildsDisplayName() {
        let name = AgentWorkspace.claudeSessionDisplayName(
            project: "-Users-\(NSUserName())-Documents-GitHub-DiskTidy",
            sessionID: "27ac3ee3-3872-45d9-984d-db142fbd18d5"
        )
        #expect(name == "Documents-GitHub-DiskTidy · 27ac3ee3")
    }

    @Test("에이전트 작업물은 정지 규칙, 기타는 보존 기간 규칙이다")
    func choosesAgeRuleByKind() {
        #expect(TempCandidateKind.claudeSession(id: "x").ageRule == .quiet(seconds: 1800))
        #expect(TempCandidateKind.codexDerivedData.ageRule == .quiet(seconds: 1800))
        #expect(TempCandidateKind.other.ageRule == .cold(seconds: Int64(TempScanner.defaultMinimumAgeDays) * 86_400))
    }
}

// MARK: - 살아 있는 세션·프로세스

@Suite("라이브 에이전트 상태")
struct LiveAgentStateTests {
    @Test("pid가 살아 있는 프로세스 기록만 취하고, 깨진 파일은 넘긴다")
    func readsLiveProcessesOnly() throws {
        let temp = try TempDirectory()
        let files = [
            "123.json": #"{"pid":123,"sessionId":"live-session","cwd":"/x","startedAt":1788396164435}"#,
            "456.json": #"{"pid":456,"sessionId":"dead-session"}"#,
            "bad.json": "not json",
            "123.abc.key": "ignored",
        ]
        for (name, contents) in files {
            try Data(contents.utf8).write(to: temp.url.appendingPathComponent(name))
        }

        let processes = LiveAgentState.liveClaudeProcesses(directory: temp.url, isAlive: { $0 == 123 })
        #expect(processes.count == 1)
        #expect(processes.first?.sessionID == "live-session")
        #expect(processes.first?.cwd == "/x")
        #expect(processes.first?.startedAt == Date(timeIntervalSince1970: 1_788_396_164.435))
    }

    @Test("startedAt이 없으면 아주 옛날에 시작한 것으로 본다")
    func missingStartFailsClosed() throws {
        let temp = try TempDirectory()
        try Data(#"{"pid":7,"sessionId":"s"}"#.utf8).write(to: temp.url.appendingPathComponent("7.json"))
        let processes = LiveAgentState.liveClaudeProcesses(directory: temp.url, isAlive: { _ in true })
        #expect(processes.first?.startedAt == .distantPast)
    }

    @Test("우리 프로세스는 살아 있고, 있을 수 없는 pid는 죽어 있다")
    func detectsProcessExistence() {
        #expect(LiveAgentState.processExists(getpid()))
        #expect(!LiveAgentState.processExists(Int32.max))
        #expect(!LiveAgentState.processExists(0))
    }

    @Test("명령줄에 경로가 있으면 사용 중이고, /tmp 표기도 같은 경로다")
    func detectsReferences() {
        let state = LiveAgentState(
            claudeProcesses: [],
            processArguments: ["xcodebuild -derivedDataPath /tmp/codex-dd-x build", "vim notes.txt"]
        )
        #expect(state.references("/private/tmp/codex-dd-x"))
        #expect(!state.references("/private/tmp/codex-dd-y"))
    }

    @Test("접두어만 같은 다른 경로의 빌드에는 걸리지 않고, 하위 경로·따옴표 뒤는 같은 경로다")
    func matchesWholePathOnly() {
        let state = LiveAgentState(
            claudeProcesses: [],
            processArguments: [
                "xcodebuild -derivedDataPath /tmp/codex-dd-red-fresh build",
                "swift build --scratch-path /private/tmp/codex-dd-sub/Build",
                #"sh -c "cd '/private/tmp/codex-dd-quoted' && make""#,
            ]
        )
        #expect(!state.references("/private/tmp/codex-dd-red"))
        #expect(state.references("/private/tmp/codex-dd-red-fresh"))
        #expect(state.references("/private/tmp/codex-dd-sub"))
        #expect(state.references("/private/tmp/codex-dd-quoted"))
    }

    @Test("프로세스 목록을 못 읽었거나 비었으면 사용 중으로 본다")
    func failsClosedWithoutProcessList() {
        for arguments in [nil, [String]()] {
            let state = LiveAgentState(claudeProcesses: [], processArguments: arguments)
            #expect(state.references("/private/tmp/codex-dd-x"))
        }
    }

    private func process(pid: Int32, session: String, cwd: String, startedAgo: TimeInterval) -> LiveAgentState.ClaudeProcess {
        LiveAgentState.ClaudeProcess(
            pid: pid, sessionID: session, cwd: cwd, startedAt: Date().addingTimeInterval(-startedAgo)
        )
    }

    /// `<projects>/<슬러그>/<세션>.jsonl`을 만들고 mtime을 `ago`초 전으로 돌린다.
    private func makeTranscript(in projects: URL, slug: String, session: String, ago: TimeInterval) throws {
        let dir = projects.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try Data("{}".utf8).write(to: url)
        let past = Date().addingTimeInterval(-ago).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(past), tv_usec: 0), timeval(tv_sec: Int(past), tv_usec: 0)]
        #expect(utimes(url.path, &times) == 0)
    }

    @Test("차단 사유는 라이브 세션과 참조 중인 빌드에만 붙는다")
    func blocksOnlyLiveWork() throws {
        let projects = try TempDirectory()
        let live = LiveAgentState(
            claudeProcesses: [process(pid: 42, session: "live", cwd: "/Users/me/Proj", startedAgo: 3600)],
            processArguments: ["xcodebuild -derivedDataPath /private/tmp/codex-dd-busy"],
            projectsDirectory: projects.url
        )
        let sessionPath = "/private/tmp/claude-501/-Users-me-Proj/live"
        #expect(AgentWorkspace.blockingReason(for: .claudeSession(id: "live"), path: sessionPath, live: live)?.contains("42") == true)
        #expect(AgentWorkspace.blockingReason(for: .claudeSession(id: "gone"), path: "/private/tmp/claude-501/-Users-me-Proj/gone", live: live) == nil)
        #expect(AgentWorkspace.blockingReason(for: .agentArtifact(claudeSessionID: "live"), path: "/p", live: live) != nil)
        #expect(AgentWorkspace.blockingReason(for: .codexDerivedData, path: "/private/tmp/codex-dd-busy", live: live) != nil)
        #expect(AgentWorkspace.blockingReason(for: .codexDerivedData, path: "/private/tmp/codex-dd-idle", live: live) == nil)
        #expect(AgentWorkspace.blockingReason(for: .other, path: "/p", live: live) == nil)
    }

    @Test("json에 없어도 트랜스크립트가 30분 안에 쓰였으면 사용 중이다")
    func recentTranscriptBlocks() throws {
        let projects = try TempDirectory()
        try makeTranscript(in: projects.url, slug: "-Users-me-Proj", session: "resumed", ago: 300)
        let live = LiveAgentState(claudeProcesses: [], processArguments: [], projectsDirectory: projects.url)

        let reason = live.claudeSessionBlockingReason(sessionID: "resumed", projectSlug: "-Users-me-Proj")
        #expect(reason?.contains("대화가 이어짐") == true)
        // 잡파일은 슬러그를 모른다. 프로젝트 전체에서 찾는다.
        #expect(live.claudeSessionBlockingReason(sessionID: "resumed", projectSlug: nil) != nil)
    }

    @Test("같은 프로젝트에서 트랜스크립트보다 먼저 시작한 프로세스가 살아 있으면 재개 중일 수 있다")
    func earlierProcessInSameProjectBlocks() throws {
        let projects = try TempDirectory()
        // 2시간 전에 마지막으로 쓰인 세션. json의 sessionId는 다른 값(처음 만든 세션)이다.
        try makeTranscript(in: projects.url, slug: "-Users-me-My-Proj", session: "old", ago: 7200)
        let resumer = process(pid: 9, session: "initial", cwd: "/Users/me/My Proj", startedAgo: 10_800)
        let live = LiveAgentState(claudeProcesses: [resumer], processArguments: [], projectsDirectory: projects.url)

        #expect(live.claudeSessionBlockingReason(sessionID: "old", projectSlug: "-Users-me-My-Proj")?.contains("PID 9") == true)
    }

    @Test("세션이 끝난 뒤 시작한 프로세스나 다른 프로젝트의 프로세스는 막지 않는다")
    func laterOrForeignProcessDoesNotBlock() throws {
        let projects = try TempDirectory()
        try makeTranscript(in: projects.url, slug: "-Users-me-Proj", session: "old", ago: 7200)
        // 1분 여유 안쪽(59초 뒤 시작)은 아직 재개 후보로 친다. 그 밖(1시간 뒤)은 아니다.
        let later = process(pid: 1, session: "x", cwd: "/Users/me/Proj", startedAgo: 3600)
        let foreign = process(pid: 2, session: "y", cwd: "/Users/me/Other", startedAgo: 10_800)
        let live = LiveAgentState(claudeProcesses: [later, foreign], processArguments: [], projectsDirectory: projects.url)

        #expect(live.claudeSessionBlockingReason(sessionID: "old", projectSlug: "-Users-me-Proj") == nil)
        // 트랜스크립트가 없는 세션은 첫 신호(json)로만 판정한다.
        #expect(live.claudeSessionBlockingReason(sessionID: "never-spoke", projectSlug: "-Users-me-Proj") == nil)
    }

    @Test("슬러그와 cwd는 영숫자만 남겨 비교한다")
    func matchesSlugs() {
        #expect(LiveAgentState.slugMatches(
            cwd: "/Users/jimmy/Library/Mobile Documents/iCloud~md~obsidian/Documents",
            slug: "-Users-jimmy-Library-Mobile-Documents-iCloud-md-obsidian-Documents"
        ))
        #expect(LiveAgentState.slugMatches(cwd: "/Users/jimmy/Documents/GitHub/ms-videoplayer-ios", slug: "-Users-jimmy-Documents-GitHub-ms-videoplayer-ios"))
        #expect(!LiveAgentState.slugMatches(cwd: "/Users/jimmy/Documents/GitHub/DiskTidy", slug: "-Users-jimmy-Documents-GitHub-DiskTidy2"))
        #expect(!LiveAgentState.slugMatches(cwd: "", slug: ""))
    }
}

// MARK: - 정지 규칙

@Suite("정지 규칙(quiet)은 mtime만 본다")
struct QuietAgeRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(modifiedAgo: TimeInterval, accessedAgo: TimeInterval) -> stat {
        var status = stat()
        status.st_uid = getuid()
        status.st_mode = S_IFREG | 0o644
        status.st_mtimespec = timespec(tv_sec: Int(now.timeIntervalSince1970 - modifiedAgo), tv_nsec: 0)
        status.st_atimespec = timespec(tv_sec: Int(now.timeIntervalSince1970 - accessedAgo), tv_nsec: 0)
        return status
    }

    @Test("방금 읽었어도 30분 넘게 안 썼으면 quiet는 통과, cold는 거부")
    func quietIgnoresAccessTime() {
        let recentlyRead = status(modifiedAgo: 3600, accessedAgo: 5)
        #expect(TempScanner.decide(
            stat: recentlyRead, path: "/private/tmp/x", rootPaths: [], openPaths: [], now: now,
            ageRule: .quiet(seconds: 1800)
        ) == .eligible)
        #expect(TempScanner.decide(
            stat: recentlyRead, path: "/private/tmp/x", rootPaths: [], openPaths: [], now: now,
            ageRule: .cold(seconds: 1800)
        ) == .tooRecent)
    }

    @Test("방금 썼으면 둘 다 거부")
    func bothRejectRecentWrite() {
        let recentlyWritten = status(modifiedAgo: 60, accessedAgo: 3600)
        for rule in [TempScanner.AgeRule.quiet(seconds: 1800), .cold(seconds: 1800)] {
            #expect(TempScanner.decide(
                stat: recentlyWritten, path: "/private/tmp/x", rootPaths: [], openPaths: [], now: now, ageRule: rule
            ) == .tooRecent)
        }
    }
}

// MARK: - 트리 안 심볼릭 링크

@Suite("에이전트 트리의 심볼릭 링크")
struct AgentTreeSymbolicLinkTests {
    private let temp: TempDirectory
    init() throws { temp = try TempDirectory() }

    /// `tree/link -> ../outside`. outside는 트리 밖 디렉터리.
    private func makeTreeWithLink() throws -> (tree: URL, outsideFile: URL) {
        let outsideFile = try temp.makeFile("outside/keep.txt", bytes: 8)
        let tree = temp.url.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("link").path, withDestinationPath: "../outside"
        )
        let past = Date().addingTimeInterval(-7200).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(past), tv_usec: 0), timeval(tv_sec: Int(past), tv_usec: 0)]
        #expect(lutimes(tree.appendingPathComponent("link").path, &times) == 0)
        #expect(utimes(tree.path, &times) == 0)
        return (tree, outsideFile)
    }

    @Test("quiet 트리는 링크를 허용하고, cold 트리는 여전히 거른다")
    func quietAllowsLinksColdDoesNot() throws {
        let fixture = try makeTreeWithLink()
        var status = stat()
        #expect(lstat(fixture.tree.path, &status) == 0)
        #expect(TempScanner.isTreeSafe(
            at: fixture.tree.path, device: status.st_dev, openPaths: [], now: Date(), ageRule: .quiet(seconds: 1800)
        ))
        #expect(!TempScanner.isTreeSafe(
            at: fixture.tree.path, device: status.st_dev, openPaths: [], now: Date(), ageRule: .cold(seconds: 1800)
        ))
    }

    @Test("removeItem은 링크를 따라가지 않는다 — 대상 파일이 남는다")
    func removeItemDoesNotFollowLinks() throws {
        let fixture = try makeTreeWithLink()
        try FileManager.default.removeItem(at: fixture.tree)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path))
        #expect(FileManager.default.fileExists(atPath: fixture.outsideFile.path))
    }
}

// MARK: - 스캔 통합

@Suite("Claude 세션 스캔 통합")
struct ClaudeSessionScanTests {
    /// `$TMPDIR/claude-<uid>/<슬러그>/<세션>/scratchpad/note.txt`를 만들고 전부 2시간 전으로 돌린다.
    /// 부모를 나중에 손대야 자식 갱신이 부모 타임스탬프를 되돌리지 않는다.
    private func makeSession(slug: String, sessionID: String) throws -> (root: URL, slug: URL, session: URL) {
        guard let tempRoot = CanonicalPath.resolve(NSTemporaryDirectory()) else {
            throw NSError(domain: "fixture", code: 1)
        }
        let claudeRoot = URL(fileURLWithPath: tempRoot).appendingPathComponent(AgentWorkspace.claudeRootName)
        let slugURL = claudeRoot.appendingPathComponent(slug)
        let sessionURL = slugURL.appendingPathComponent(sessionID)
        let scratch = sessionURL.appendingPathComponent("scratchpad")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let note = scratch.appendingPathComponent("note.txt")
        try Data(repeating: 0x41, count: 256).write(to: note)

        let past = Date().addingTimeInterval(-7200).timeIntervalSince1970
        for url in [note, scratch, sessionURL] {
            var times = [
                timeval(tv_sec: Int(past), tv_usec: 0),
                timeval(tv_sec: Int(past), tv_usec: 0),
            ]
            #expect(utimes(url.path, &times) == 0)
        }
        return (claudeRoot, slugURL, sessionURL)
    }

    private func cleanUp(_ fixture: (root: URL, slug: URL, session: URL)) {
        try? FileManager.default.removeItem(at: fixture.slug)
        // 다른 테스트의 슬러그가 남아 있으면 실패한다. 비어 있을 때만 걷힌다.
        rmdir(fixture.root.path)
    }

    @Test("끝난 세션의 스크래치는 오늘 만들어졌어도 후보다")
    func endedSessionBecomesCandidate() throws {
        let sessionID = UUID().uuidString.lowercased()
        let fixture = try makeSession(slug: "DiskTidyTests-\(UUID().uuidString)", sessionID: sessionID)
        defer { cleanUp(fixture) }

        let live = LiveAgentState(claudeProcesses: [], processArguments: [])
        let found = try TempScanner.scan(live: live).first { $0.canonicalPath == fixture.session.path }
        let candidate = try #require(found)
        #expect(candidate.kind == .claudeSession(id: sessionID))
        #expect(candidate.isDeletable)
        #expect(candidate.evidence.contains("세션 종료"))
        #expect(candidate.name.hasSuffix(String(sessionID.prefix(8))))
    }

    @Test("살아 있는 세션은 사용 중 행으로만 올라오고 지울 수 없다")
    func liveSessionIsShownButNotDeletable() throws {
        let sessionID = UUID().uuidString.lowercased()
        let fixture = try makeSession(slug: "DiskTidyTests-\(UUID().uuidString)", sessionID: sessionID)
        defer { cleanUp(fixture) }

        let live = LiveAgentState(
            claudeProcesses: [LiveAgentState.ClaudeProcess(pid: 4242, sessionID: sessionID, cwd: "/", startedAt: Date())],
            processArguments: []
        )
        let found = try TempScanner.scan(live: live).first { $0.canonicalPath == fixture.session.path }
        let row = try #require(found)
        #expect(row.isInUse)
        #expect(!row.isDeletable)
        #expect(row.evidence.contains("4242"))

        // 삭제기도 같은 판단을 한다. UI를 우회해 넘겨도 거부된다.
        #expect(PermanentDeleter.delete(row) == .refused(.inUse))
    }

    @Test("Claude 루트와 슬러그 디렉터리 자체는 후보가 아니다")
    func rootAndSlugAreNeverCandidates() throws {
        let fixture = try makeSession(slug: "DiskTidyTests-\(UUID().uuidString)", sessionID: UUID().uuidString.lowercased())
        defer { cleanUp(fixture) }

        let paths = Set(try TempScanner.scan(live: LiveAgentState(claudeProcesses: [], processArguments: [])).map(\.canonicalPath))
        #expect(!paths.contains(fixture.root.path))
        #expect(!paths.contains(fixture.slug.path))
    }
}
