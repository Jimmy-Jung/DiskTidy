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
/// 답변은 조각 단위로 흘려 받는다. `--output-format stream-json`의 NDJSON을 줄마다
/// 해석하며(`AICLIStreamParser`) 프로세스 종료를 기다리지 않는다.
struct AICLIClient {
    /// CLI 응답을 기다리는 상한. 첫 토큰까지 수십 초가 걸리는 경우가 있어 넉넉히 둔다.
    static let timeout: TimeInterval = 180

    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        /// 실수로 파일을 건드려도 저장소가 아니라 임시 디렉터리에서 일어나게 한다.
        let workingDirectory: URL
    }

    private let run: @Sendable (Invocation) -> AsyncStream<ShellStreamEvent>

    init(
        run: @escaping @Sendable (Invocation) -> AsyncStream<ShellStreamEvent> = { invocation in
            ShellRunner.streamLines(
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
                // CLI가 보고한 실패 사유. 종료 코드보다 이쪽이 구체적이라 우선한다.
                var reportedFailure: String?
                var exitCode: Int32 = 0

                for await event in run(invocation) {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .line(let line):
                        switch AICLIStreamParser.event(from: line) {
                        case .text(let text): continuation.yield(.text(text))
                        case .truncated: continuation.yield(.truncated)
                        case .failure(let message): reportedFailure = message
                        case .done, .ignored: continue
                        }
                    case .exit(let code):
                        exitCode = code
                    }
                }

                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                if let reportedFailure {
                    continuation.finish(
                        throwing: AIChatError.cliFailed(
                            exitCode: exitCode, message: reportedFailure
                        )
                    )
                    return
                }
                guard exitCode == 0 else {
                    // stderr는 ShellRunner가 버리므로(파이프 교착 회피) 남은 근거가 없다.
                    continuation.finish(
                        throwing: AIChatError.cliFailed(
                            exitCode: exitCode,
                            message: "출력이 없습니다. 로그인 상태를 확인하세요."
                        )
                    )
                    return
                }
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
                // 조각 단위로 받으려면 세 개가 다 필요하다. `stream-json`만 주면 CLI가
                // 블록이 끝난 뒤 완성본(`assistant`)만 보내서 결국 한 덩어리로 온다.
                // `--verbose`는 print 모드에서 stream-json을 쓸 때 CLI가 요구한다.
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
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
