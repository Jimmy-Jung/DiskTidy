import Foundation

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

        // 자리표시 답변을 미리 넣고 조각이 올 때마다 이어 붙인다.
        // 인덱스가 아니라 id로 찾는다 — 스트리밍 중 "새 대화"를 누르면 인덱스가 어긋난다.
        let replyID = UUID()
        messages.append(AIChatMessage(id: replyID, role: .assistant, text: ""))
        isStreaming = true

        streamTask = Task {
            var wasTruncated = false
            do {
                for try await chunk in makeStream() {
                    // 취소 확인이 없으면 취소 뒤에도 버퍼에 남은 조각을 계속 이어 붙이고,
                    // 그 사이 시작된 새 스트림의 상태를 아래 마무리 코드가 덮어쓴다.
                    if Task.isCancelled { break }
                    guard let index = self.messages.firstIndex(where: { $0.id == replyID })
                    else { return }
                    switch chunk {
                    case .text(let text): self.messages[index].text += text
                    case .truncated: wasTruncated = true
                    }
                }
            } catch {
                self.errorMessage = AIChatError.describe(error)
            }

            // 취소된 Task는 마무리를 하지 않는다. 새 스트림이 이미 상태를 쥐고 있다.
            guard !Task.isCancelled else { return }
            self.isStreaming = false

            guard let index = self.messages.firstIndex(where: { $0.id == replyID }) else { return }
            if self.messages[index].text.isEmpty {
                // 한 글자도 못 받은 자리는 빈 말풍선으로 남기지 않는다. 다만 조용히 지우면
                // 아무 일도 없었던 것처럼 보이므로 사유를 남긴다.
                self.messages.remove(at: index)
                if self.errorMessage == nil {
                    self.errorMessage = "응답을 받지 못했습니다. 모델 이름과 API 루트 URL을 확인하세요."
                }
            } else if wasTruncated {
                self.messages[index].text += "\n\n(답변이 길이 제한으로 잘렸습니다.)"
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        // 취소된 Task는 마무리를 건너뛰므로 빈 자리표시는 여기서 치운다.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
        }
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
