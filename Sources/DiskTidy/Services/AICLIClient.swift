import Foundation

/// 이미 로그인된 공식 CLI를 그대로 실행해 답변을 받는다. **개발 빌드 전용.**
///
/// 왜 이 방식인가:
/// - 구독 OAuth 토큰을 꺼내 HTTP API에 붙이는 방식은 제공자가 서버에서 차단하고 계정 정지
///   사유다. 여기서는 토큰을 읽지도, 헤더를 위장하지도 않는다. 사용자가 터미널에서 직접
///   치는 것과 같은 명령을 같은 자격증명으로 실행할 뿐이다.
/// - 배포 빌드에서는 `stream(_:)`이 곧바로 실패한다. 서드파티 앱이 사용자 구독으로 요청을
///   대행하는 것은 제공자 약관이 금지한다.
///
/// 한계: 조각 단위 스트리밍을 하지 않는다 — 한 번에 받아 한 덩어리로 올린다.
/// CLI의 stream-json 형식은 도구마다 달라서, 필요해지면 그때 도구별 파서를 붙인다.
struct AICLIClient {
    /// CLI 응답을 기다리는 상한. 첫 토큰까지 수십 초가 걸리는 경우가 있어 넉넉히 둔다.
    static let timeout: TimeInterval = 180

    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        /// 실수로 파일을 건드려도 저장소가 아니라 임시 디렉터리에서 일어나게 한다.
        let workingDirectory: URL
    }

    private let run: @Sendable (Invocation) -> ShellResult

    init(
        run: @escaping @Sendable (Invocation) -> ShellResult = { invocation in
            ShellRunner.run(
                invocation.executable,
                invocation.arguments,
                workingDirectory: invocation.workingDirectory,
                timeout: AICLIClient.timeout
            )
        }
    ) {
        self.run = run
    }

    static func makeInvocation(
        tool: AICLITool,
        executablePath: String,
        model: String,
        systemPrompt: String,
        messages: [AIChatMessage]
    ) throws -> Invocation {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw AIChatError.cliNotFound(path)
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw AIChatError.missingModel }

        return Invocation(
            executable: path,
            arguments: arguments(
                tool: tool,
                model: trimmedModel,
                systemPrompt: systemPrompt,
                messages: messages
            ),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }

    func stream(_ invocation: Invocation) -> AsyncThrowingStream<AIChatChunk, Error> {
        AsyncThrowingStream { continuation in
            #if DEBUG
            let run = self.run
            let task = Task {
                // CLI는 수십 초를 쓴다. 메인 스레드에서 기다리면 앱이 통째로 멈춘다.
                let result = await Task.detached(priority: .userInitiated) {
                    run(invocation)
                }.value

                if Task.isCancelled {
                    continuation.finish()
                    return
                }

                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.succeeded else {
                    // stderr는 ShellRunner가 버리므로(파이프 교착 회피) stdout만 근거가 된다.
                    continuation.finish(
                        throwing: AIChatError.cliFailed(
                            exitCode: result.exitCode,
                            message: output.isEmpty ? "출력이 없습니다. 로그인 상태를 확인하세요." : output
                        )
                    )
                    return
                }
                if !output.isEmpty { continuation.yield(.text(output)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: AIChatError.debugOnlyProvider)
            #endif
        }
    }

    // MARK: - 명령 조립 (순수 함수)

    /// CLI는 호출마다 상태가 없다. 대화 전체를 하나의 프롬프트로 넘긴다.
    static func transcript(_ messages: [AIChatMessage]) -> String {
        messages
            .map { ($0.role == .user ? "사용자: " : "도우미: ") + $0.text }
            .joined(separator: "\n\n")
    }

    static func arguments(
        tool: AICLITool,
        model: String,
        systemPrompt: String,
        messages: [AIChatMessage]
    ) -> [String] {
        switch tool {
        case .claudeCode:
            return [
                "-p", transcript(messages),
                "--model", model,
                "--output-format", "text",
                "--append-system-prompt", systemPrompt,
                // 화면 스냅샷을 이미 프롬프트에 담아 넘긴다. 도구는 필요 없고, 열어 두면
                // 이 앱이 사용자 파일을 고치거나 명령을 실행하는 경로가 된다.
                "--disallowed-tools", "Bash", "Edit", "Write", "NotebookEdit",
                "WebFetch", "WebSearch", "Task", "Read", "Glob", "Grep",
                // 전역 설정의 MCP 서버를 끌어오지 않는다. 느리고 부작용이 있다.
                "--strict-mcp-config",
            ]
        }
    }
}
