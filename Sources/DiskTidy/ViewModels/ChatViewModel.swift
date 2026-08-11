import Foundation
import MarkdownView

/// 오른쪽 챗봇 패널의 대화 상태.
///
/// 화면 스냅샷은 매 요청의 시스템 프롬프트에 새로 넣는다. 첫 질문에만 넣으면
/// 스캔이 끝나 목록이 바뀐 뒤에도 모델이 옛 숫자를 근거로 답한다.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [AIChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isStreaming = false
    @Published var errorMessage: String?

    /// 지금 흘러오는 답변의 마크다운 원본.
    ///
    /// 조각을 `messages`에 바로 이어 붙이지 않는다. `@Published` 배열을 토큰마다 고치면
    /// 목록 전체가 매 토큰 다시 계산되고, 답변이 길수록 그 비용이 쌓인다.
    /// `StreamingMarkdownSource`는 자기 스트림으로 값을 나르므로 SwiftUI 갱신을
    /// 건드리지 않고, 화면은 라이브러리가 정한 간격(기본 50ms)으로만 다시 그린다.
    /// 본문은 스트림이 끝날 때 `messages`로 한 번에 옮긴다.
    @Published private(set) var streamingSource: StreamingMarkdownSource?

    /// 스트리밍 중인 답변의 id. 그 말풍선만 `streamingSource`로 그린다.
    @Published private(set) var streamingReplyID: UUID?

    /// 요청은 보냈는데 첫 조각이 아직 안 왔다.
    ///
    /// 이 구간이 짧지 않다. CLI 제공자는 기동에 몇 초를 쓰고, 모델이 사고 블록을 먼저
    /// 흘리는 동안에는 본문이 하나도 오지 않는다(실측 7초). 그동안 답변 자리가 비어
    /// 있으면 멈춘 것처럼 보이므로 그 자리에 진행 표시를 둔다.
    @Published private(set) var isAwaitingFirstChunk = false

    private let client: AIChatClient
    private let cliClient: AICLIClient
    private var streamTask: Task<Void, Never>?

    init(client: AIChatClient = AIChatClient(), cliClient: AICLIClient = AICLIClient()) {
        self.client = client
        self.cliClient = cliClient
    }

    var canSend: Bool {
        !isStreaming && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(settings: AISettings, apiKey: String?, context: ScreenContext) {
        guard !isStreaming else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        input = ""
        errorMessage = nil
        messages.append(AIChatMessage(role: .user, text: question))

        // 전송 준비는 여기서 끝낸다. 실패 사유(키 없음·CLI 없음 등)를 스트림 안에서
        // 알리면 사용자는 빈 말풍선을 먼저 보게 된다.
        let systemPrompt = Self.systemPrompt(context: context)
        let makeStream: () -> AsyncThrowingStream<AIChatChunk, Error>
        do {
            switch settings.provider.transport {
            case .http(let format):
                let request = try AIRequestBuilder.makeRequest(
                    settings: settings,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    messages: messages
                )
                let client = self.client
                makeStream = { client.stream(request: request, format: format) }
            case .localCLI(let tool):
                let invocation = try AICLIClient.makeInvocation(
                    tool: tool,
                    executablePath: settings.baseURL,
                    model: settings.model,
                    systemPrompt: systemPrompt,
                    messages: messages
                )
                let cliClient = self.cliClient
                makeStream = { cliClient.stream(invocation) }
            }
        } catch {
            errorMessage = AIChatError.describe(error)
            return
        }

        // 자리표시 답변을 미리 넣고, 조각은 `messages`가 아니라 스트리밍 원본에 쌓는다.
        let replyID = UUID()
        let source = StreamingMarkdownSource()
        messages.append(AIChatMessage(id: replyID, role: .assistant, text: ""))
        streamingSource = source
        streamingReplyID = replyID
        isStreaming = true
        isAwaitingFirstChunk = true

        streamTask = Task {
            var wasTruncated = false
            do {
                for try await chunk in makeStream() {
                    // 취소 확인이 없으면 취소 뒤에도 버퍼에 남은 조각을 계속 이어 붙이고,
                    // 그 사이 시작된 새 스트림의 상태를 아래 마무리 코드가 덮어쓴다.
                    if Task.isCancelled { break }
                    switch chunk {
                    case .text(let text):
                        // 첫 조각에서 한 번만 발행한다. 조각마다 쓰면 목록 전체가 다시 계산된다.
                        if self.isAwaitingFirstChunk { self.isAwaitingFirstChunk = false }
                        source.text += text
                    case .truncated:
                        wasTruncated = true
                    }
                }
            } catch {
                self.errorMessage = AIChatError.describe(error)
            }

            // 취소된 Task는 마무리를 하지 않는다. `cancel()`이 이미 마무리했고,
            // 새 스트림이 상태를 쥐고 있을 수도 있다.
            guard !Task.isCancelled else { return }
            self.finishStreaming(truncated: wasTruncated, reportsEmptyAnswer: true)
        }
    }

    /// 스트림이 끝났다. 받은 본문을 `messages`로 옮기는 유일한 지점이다.
    ///
    /// - Parameter reportsEmptyAnswer: 한 글자도 못 받았을 때 사유를 배너로 띄울지.
    ///   사용자가 직접 중단한 경우는 오류가 아니므로 끈다.
    private func finishStreaming(truncated: Bool, reportsEmptyAnswer: Bool) {
        guard let source = streamingSource, let replyID = streamingReplyID else { return }
        source.finishStreaming()
        streamingSource = nil
        streamingReplyID = nil
        isStreaming = false
        isAwaitingFirstChunk = false

        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
        let answer = source.text
        if answer.isEmpty {
            // 한 글자도 못 받은 자리는 빈 말풍선으로 남기지 않는다. 다만 조용히 지우면
            // 아무 일도 없었던 것처럼 보이므로 사유를 남긴다.
            messages.remove(at: index)
            if reportsEmptyAnswer, errorMessage == nil {
                errorMessage = "응답을 받지 못했습니다. 모델 이름과 API 루트 URL을 확인하세요."
            }
        } else if truncated {
            messages[index].text = answer + "\n\n(답변이 길이 제한으로 잘렸습니다.)"
        } else {
            messages[index].text = answer
        }
    }

    /// 마지막 답변을 버리고 같은 질문을 다시 보낸다.
    ///
    /// 답변만 지우고 다시 물으면 모델이 앞 답변을 대화에 남아 있는 것으로 보고 이어서
    /// 말한다. 그래서 마지막 질문 이후를 통째로 버린 뒤 같은 질문을 새로 보낸다.
    func regenerateLastAnswer(settings: AISettings, apiKey: String?, context: ScreenContext) {
        guard !isStreaming,
              let index = messages.lastIndex(where: { $0.role == .user })
        else { return }

        input = messages[index].text
        messages.removeSubrange(index...)
        send(settings: settings, apiKey: apiKey, context: context)
    }

    /// 이 질문을 입력창으로 되돌리고 그 뒤 대화를 버린다. 고쳐서 다시 보내는 용도다.
    func moveMessageToInput(id: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        input = messages[index].text
        messages.removeSubrange(index...)
    }

    /// 마지막 답변인지. 재생성 버튼은 대화 끝에서만 뜻이 통한다.
    func isLastAnswer(_ message: AIChatMessage) -> Bool {
        message.role == .assistant && messages.last?.id == message.id
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        // 취소된 Task는 마무리를 건너뛰므로 여기서 마무리한다. 받은 만큼은 남기고,
        // 한 글자도 없으면 빈 말풍선을 치운다.
        finishStreaming(truncated: false, reportsEmptyAnswer: false)
        isStreaming = false
    }

    func clear() {
        cancel()
        messages = []
        errorMessage = nil
    }

    /// 모델이 지켜야 할 경계. 이 앱은 사용자 파일을 지우므로 되돌릴 수 있는지 여부를
    /// 반드시 함께 말하게 하고, 화면에 없는 값을 지어내지 못하게 막는다.
    nonisolated static func systemPrompt(context: ScreenContext) -> String {
        """
        당신은 macOS 디스크 정리 앱 DiskTidy에 내장된 도우미입니다. 사용자가 지금 보고 있는 \
        화면의 스냅샷만을 근거로 한국어로 간결하게 답합니다.

        규칙:
        - 스냅샷에 없는 수치·경로·항목은 지어내지 말고 "화면 정보로는 알 수 없다"고 답합니다.
        - 삭제를 권할 때는 되돌릴 수 있는지(휴지통) 없는지(완전 삭제·simctl·프로세스 종료)를 \
        반드시 함께 밝힙니다.
        - 당신은 앱을 조작할 수 없습니다. 실제 실행은 사용자가 직접 버튼을 눌러야 합니다.
        - 목록은 화면 표시 순서이며 길면 일부만 들어 있습니다. 합계는 목록이 아니라 \
        합계 줄을 근거로 답합니다.

        \(context.promptText)
        """
    }
}
