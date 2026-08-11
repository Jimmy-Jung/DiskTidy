import Foundation

/// AI에게 설명을 물을 대상 하나.
///
/// 탭마다 항목의 형태가 다르다 — 폴더, 시뮬레이터, 실행 중인 프로세스. 경로가 없는 것도
/// 있어서 캐시 키를 `URL`로 둘 수 없다. 각 탭이 자기 항목을 이 구조로 옮겨 넘긴다.
struct ExplanationSubject: Equatable {
    /// 캐시 키. 같은 대상이면 새로고침 뒤에도 같은 값이어야 한다.
    let key: String
    /// 팝오버 제목.
    let title: String
    /// 제목 아래 작게 붙는 줄. 보통 경로.
    let subtitle: String?
    /// 프롬프트에 그대로 들어갈 사실들. 모델이 이것만 근거로 삼는다.
    let facts: [String]
}

extension ExplanationSubject {
    /// 목록 항목. 경로가 캐시 키다 — `CleanableItem.id`는 매번 새로 만드는 UUID라서
    /// id로 캐시하면 새로고침할 때마다 같은 폴더를 다시 물어본다.
    init(item: CleanableItem, action: String) {
        var facts = [
            "항목: \(item.name)",
            "경로: \(item.path.path)",
            "크기: \(item.sizeString)",
            "이 화면의 정리 방식: \(action)",
        ]
        if let modified = item.modifiedDateString { facts.append("마지막 수정: \(modified)") }
        self.init(
            key: item.path.path,
            title: item.name,
            subtitle: item.path.path,
            facts: facts
        )
    }
}

/// 항목 하나가 무엇인지 AI에게 짧게 물어 캐시한다.
///
/// 요청은 **버튼을 눌렀을 때만** 나간다. 마우스를 올릴 때 물으면 목록을 훑는 것만으로
/// 항목 수만큼 요청이 나가고, CLI 제공자는 호출마다 프로세스를 띄운다.
@MainActor
final class ItemExplanationStore: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(String)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    private let client: AIChatClient
    private let cliClient: AICLIClient
    private var tasks: [String: Task<Void, Never>] = [:]

    init(client: AIChatClient = AIChatClient(), cliClient: AICLIClient = AICLIClient()) {
        self.client = client
        self.cliClient = cliClient
    }

    func state(for subject: ExplanationSubject) -> State? {
        states[subject.key]
    }

    /// 이미 받아 둔 설명이나 진행 중인 요청이 있으면 아무것도 하지 않는다.
    func explain(
        _ subject: ExplanationSubject,
        screenTitle: String,
        settings: AISettings,
        apiKey: String?
    ) {
        guard states[subject.key] == nil, tasks[subject.key] == nil else { return }

        // 전송 준비는 여기서 끝낸다. 실패 사유(경로 오류·CLI 없음)를 스트림 안에서 알리면
        // 사용자는 빈 팝오버를 먼저 보게 된다.
        let fast = settings.usingFastModel()
        let messages = [
            AIChatMessage(role: .user, text: Self.question(for: subject, screenTitle: screenTitle))
        ]
        let makeStream: () -> AsyncThrowingStream<AIChatChunk, Error>
        do {
            switch fast.provider.transport {
            case .http(let format):
                let request = try AIRequestBuilder.makeRequest(
                    settings: fast,
                    apiKey: apiKey,
                    systemPrompt: Self.systemPrompt,
                    messages: messages
                )
                let client = self.client
                makeStream = { client.stream(request: request, format: format) }
            case .localCLI(let tool):
                let invocation = try AICLIClient.makeInvocation(
                    tool: tool,
                    executablePath: fast.baseURL,
                    model: fast.model,
                    systemPrompt: Self.systemPrompt,
                    messages: messages
                )
                let cliClient = self.cliClient
                makeStream = { cliClient.stream(invocation) }
            }
        } catch {
            states[subject.key] = .failed(AIChatError.describe(error))
            return
        }

        states[subject.key] = .loading
        let key = subject.key
        tasks[key] = Task {
            var text = ""
            do {
                for try await chunk in makeStream() {
                    if case .text(let piece) = chunk { text += piece }
                }
            } catch {
                self.finish(key: key, state: .failed(AIChatError.describe(error)))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 한 글자도 못 받은 것을 빈 설명으로 보여 주면 고장인지 답이 없는 건지 모른다.
            self.finish(
                key: key,
                state: trimmed.isEmpty ? .failed("설명을 받지 못했습니다.") : .ready(trimmed)
            )
        }
    }

    /// 대상을 다시 물어볼 수 있게 캐시를 비운다.
    func forget(_ subject: ExplanationSubject) {
        tasks[subject.key]?.cancel()
        tasks[subject.key] = nil
        states[subject.key] = nil
    }

    private func finish(key: String, state: State) {
        tasks[key] = nil
        states[key] = state
    }

    // MARK: - 프롬프트 (순수 함수)

    /// 대화 챗봇과 규칙이 다르다. 여기서는 화면 스냅샷 없이 대상 하나만 주므로, 모델이
    /// 아는 일반 지식으로 답하게 하되 **주어진 사실에서 읽히지 않는 것은 지어내지 못하게**
    /// 막는다.
    ///
    /// 순서를 못 박아 둔다. "지우면 잃는 것"을 먼저 쓰게 하면 정작 **이게 무엇인지**가
    /// 뒤로 밀려, 사용자는 처음 보는 이름을 그대로 둔 채 위험 문구만 읽게 된다.
    static let systemPrompt = """
    당신은 macOS 디스크 정리 앱의 도우미입니다. 사용자가 목록의 항목 하나를 가리켰습니다. \
    한국어로 세 문장 이내로 답합니다.

    이 순서를 지킵니다:
    1. 이것이 **무엇인지** — 어떤 도구가 만들었고 무엇이 담기는 자리인지 먼저 밝힙니다.
    2. 정리해도 되는지 — 다시 만들어지는지(재빌드·재다운로드·재실행으로 복구되는지).
    3. 잃는 것이 있으면 그것.

    규칙:
    - 이름과 경로에서 무엇인지 알 수 없으면 "이름과 경로로는 알 수 없다"고 답합니다. \
    추측을 사실처럼 쓰지 않습니다.
    - 주어진 정리 방식이 되돌릴 수 없는 것이면 그 사실을 빠뜨리지 않습니다.
    - 목록·제목·머리말 없이 문장만 씁니다. 경로를 그대로 되풀어 쓰지 않습니다.
    """

    static func question(for subject: ExplanationSubject, screenTitle: String) -> String {
        (["화면: \(screenTitle)"] + subject.facts).joined(separator: "\n")
    }
}
