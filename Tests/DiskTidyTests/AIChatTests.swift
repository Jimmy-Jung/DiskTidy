import Foundation
import Testing

@testable import DiskTidy

// MARK: - 테스트 대역

/// 실제 키체인을 건드리면 사용자의 키가 지워진다. 메모리에만 담는다.
final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let alwaysFails: Bool

    init(alwaysFails: Bool = false, seeded: [String: String] = [:]) {
        self.alwaysFails = alwaysFails
        storage = seeded
    }

    func key(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func setKey(_ key: String?, for account: String) -> Bool {
        if alwaysFails { return false }
        lock.lock()
        defer { lock.unlock() }
        if let key, !key.isEmpty {
            storage[account] = key
        } else {
            storage.removeValue(forKey: account)
        }
        return true
    }
}

/// 설정 값을 메모리에만 담는다. `UserDefaults(suiteName:)`를 쓰면 사용자 홈
/// (`~/Library/Preferences`)에 plist가 생기고, 지워도 cfprefsd가 비동기로 다시 쓴다 —
/// CONTRIBUTING의 "사용자 홈을 건드리는 테스트는 받지 않는다".
final class InMemorySettingsStore: SettingsStore {
    private var storage: [String: String] = [:]

    func string(forKey key: String) -> String? { storage[key] }
    func setString(_ value: String, forKey key: String) { storage[key] = value }
}

/// 네트워크를 타지 않고 HTTP 응답을 흉내낸다. 실제 API를 부르면 테스트가 키와 요금을 요구한다.
final class StubURLProtocol: URLProtocol {
    /// 응답을 세션별 토큰으로 격리한다. 전역 static 하나를 공유하면 병렬로 도는
    /// 다른 스위트가 그 값을 덮어써서 엉뚱한 상태 코드를 보게 된다(실제로 겪음).
    private static let lock = NSLock()
    private static var responses: [String: (status: Int, body: String)] = [:]
    private static let tokenHeader = "X-DiskTidy-Stub-Token"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        Self.lock.lock()
        let stub = Self.responses[token]
        Self.lock.unlock()

        guard let url = request.url, let stub,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeClient(status: Int, body: String) -> AIChatClient {
        let token = UUID().uuidString
        lock.lock()
        responses[token] = (status, body)
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [tokenHeader: token]
        return AIChatClient(session: URLSession(configuration: configuration))
    }
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - 엔드포인트 URL

@Suite("AI 엔드포인트 URL")
struct AIEndpointURLTests {
    @Test("제공자별 기본 루트에 형식 경로가 붙는다")
    func defaultRoots() throws {
        let anthropic = try AIRequestBuilder.endpointURL(
            base: "https://api.anthropic.com", format: .anthropicMessages
        )
        #expect(anthropic.absoluteString == "https://api.anthropic.com/v1/messages")

        let openAI = try AIRequestBuilder.endpointURL(
            base: "https://api.openai.com", format: .openAIChatCompletions
        )
        #expect(openAI.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("끝 슬래시와 사용자가 붙인 /v1을 흡수한다")
    func normalizesUserInput() throws {
        let withSlash = try AIRequestBuilder.endpointURL(
            base: "https://api.openai.com/", format: .openAIChatCompletions
        )
        #expect(withSlash.absoluteString == "https://api.openai.com/v1/chat/completions")

        // 사용자가 문서를 보고 /v1을 직접 붙이는 일이 흔하다. /v1/v1이 되면 안 된다.
        let withVersion = try AIRequestBuilder.endpointURL(
            base: "https://api.openai.com/v1/", format: .openAIChatCompletions
        )
        #expect(withVersion.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("문서의 전체 엔드포인트 URL을 그대로 붙여넣어도 경로가 두 번 붙지 않는다")
    func absorbsFullEndpointPath() throws {
        let openAI = try AIRequestBuilder.endpointURL(
            base: "https://api.openai.com/v1/chat/completions", format: .openAIChatCompletions
        )
        #expect(openAI.absoluteString == "https://api.openai.com/v1/chat/completions")

        let anthropic = try AIRequestBuilder.endpointURL(
            base: "https://api.anthropic.com/v1/messages", format: .anthropicMessages
        )
        #expect(anthropic.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("게이트웨이의 경로 접두사는 보존한다")
    func keepsGatewayPrefix() throws {
        let url = try AIRequestBuilder.endpointURL(
            base: "https://gateway.example.com/llm", format: .openAIChatCompletions
        )
        #expect(url.absoluteString == "https://gateway.example.com/llm/v1/chat/completions")
    }

    @Test("루프백 평문 http는 허용한다", arguments: [
        "http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434",
    ])
    func allowsLoopbackPlaintext(base: String) throws {
        // URLComponents는 IPv6 호스트를 대괄호째 돌려준다. 벗기지 않으면 ::1이 거부된다.
        let url = try AIRequestBuilder.endpointURL(base: base, format: .openAIChatCompletions)
        #expect(url.path == "/v1/chat/completions")
    }

    @Test("*.local 평문은 키가 필요 없는 제공자에만 허용한다")
    func lanPlaintextIsGatedByKeyRequirement() throws {
        let allowed = try AIRequestBuilder.endpointURL(
            base: "http://gpu-box.local:8000",
            format: .openAIChatCompletions,
            allowsLANPlaintext: true
        )
        #expect(allowed.path == "/v1/chat/completions")

        // 키를 요구하는 제공자에 허용하면 API 키가 LAN을 평문으로 지난다.
        #expect(throws: AIChatError.insecureEndpoint("gpu-box.local")) {
            try AIRequestBuilder.endpointURL(
                base: "http://gpu-box.local:8000",
                format: .openAIChatCompletions,
                allowsLANPlaintext: false
            )
        }
    }

    @Test("원격 평문 http는 거부한다")
    func rejectsRemotePlaintext() {
        #expect(throws: AIChatError.insecureEndpoint("api.example.com")) {
            try AIRequestBuilder.endpointURL(
                base: "http://api.example.com",
                format: .openAIChatCompletions,
                allowsLANPlaintext: true
            )
        }
    }

    @Test("URL 형식이 아니면 거부한다", arguments: ["", "   ", "api.openai.com", "ftp://x.com"])
    func rejectsMalformed(base: String) {
        #expect(throws: AIChatError.invalidBaseURL(base)) {
            try AIRequestBuilder.endpointURL(base: base, format: .anthropicMessages)
        }
    }
}

// MARK: - 요청 만들기

@Suite("AI 요청 생성")
struct AIRequestBuilderTests {
    private let systemPrompt = "화면 스냅샷"
    private let messages = [AIChatMessage(role: .user, text: "이 화면 요약해줘")]

    @Test("Anthropic 요청은 x-api-key와 버전 헤더를 쓴다")
    func anthropicHeadersAndBody() throws {
        let request = try AIRequestBuilder.makeRequest(
            settings: AISettings(provider: .anthropic),
            apiKey: "sk-test-key",
            systemPrompt: systemPrompt,
            messages: messages
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try jsonBody(request)
        #expect(body["system"] as? String == systemPrompt)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == AIRequestBuilder.maximumOutputTokens)

        let turns = try #require(body["messages"] as? [[String: String]])
        #expect(turns == [["role": "user", "content": "이 화면 요약해줘"]])
    }

    @Test("OpenAI 요청은 Bearer 헤더와 system 메시지를 쓴다")
    func openAIHeadersAndBody() throws {
        let request = try AIRequestBuilder.makeRequest(
            settings: AISettings(provider: .openAI),
            apiKey: "sk-test-key",
            systemPrompt: systemPrompt,
            messages: messages
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)

        let body = try jsonBody(request)
        #expect(body["system"] == nil)
        let turns = try #require(body["messages"] as? [[String: String]])
        #expect(turns.first == ["role": "system", "content": systemPrompt])
        #expect(turns.last == ["role": "user", "content": "이 화면 요약해줘"])
    }

    @Test("OpenAI 본가는 max_completion_tokens, 호환 서버는 max_tokens를 쓴다")
    func outputTokenParameterName() throws {
        // 추론 계열 모델(o1·o3·gpt-5)은 max_tokens를 400으로 거부한다.
        let openAI = try jsonBody(
            AIRequestBuilder.makeRequest(
                settings: AISettings(provider: .openAI),
                apiKey: "sk-test-key",
                systemPrompt: systemPrompt,
                messages: messages
            )
        )
        #expect(openAI["max_completion_tokens"] as? Int == AIRequestBuilder.maximumOutputTokens)
        #expect(openAI["max_tokens"] == nil)

        // 반대로 로컬·호환 서버는 새 이름을 모르는 구현이 많다.
        let ollama = try jsonBody(
            AIRequestBuilder.makeRequest(
                settings: AISettings(provider: .ollama),
                apiKey: nil,
                systemPrompt: systemPrompt,
                messages: messages
            )
        )
        #expect(ollama["max_tokens"] as? Int == AIRequestBuilder.maximumOutputTokens)
        #expect(ollama["max_completion_tokens"] == nil)
    }

    @Test("로컬 제공자에는 콜드 스타트를 견디는 타임아웃을 준다")
    func localProviderGetsLongerTimeout() throws {
        let remote = try AIRequestBuilder.makeRequest(
            settings: AISettings(provider: .anthropic),
            apiKey: "sk-test-key",
            systemPrompt: systemPrompt,
            messages: messages
        )
        let local = try AIRequestBuilder.makeRequest(
            settings: AISettings(provider: .ollama),
            apiKey: nil,
            systemPrompt: systemPrompt,
            messages: messages
        )
        #expect(local.timeoutInterval > remote.timeoutInterval)
    }

    @Test("API 키는 본문에 절대 들어가지 않는다")
    func keyNeverInBody() throws {
        for provider in AIProvider.allCases where provider.requiresAPIKey {
            var settings = AISettings(provider: provider)
            if settings.baseURL.isEmpty { settings.baseURL = "https://api.example.com" }
            if settings.model.isEmpty { settings.model = "test-model" }

            let request = try AIRequestBuilder.makeRequest(
                settings: settings,
                apiKey: "sk-secret-value",
                systemPrompt: systemPrompt,
                messages: messages
            )
            let raw = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(!raw.contains("sk-secret-value"))
        }
    }

    @Test("키가 필요한 제공자는 키 없이 요청을 만들지 않는다", arguments: [nil, "", "   "])
    func missingKeyIsRejected(key: String?) {
        #expect(throws: AIChatError.missingAPIKey) {
            try AIRequestBuilder.makeRequest(
                settings: AISettings(provider: .anthropic),
                apiKey: key,
                systemPrompt: "s",
                messages: []
            )
        }
    }

    @Test("로컬 제공자는 키 없이도 요청을 만든다")
    func localProviderNeedsNoKey() throws {
        let request = try AIRequestBuilder.makeRequest(
            settings: AISettings(provider: .ollama),
            apiKey: nil,
            systemPrompt: systemPrompt,
            messages: messages
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("모델이 비면 요청을 만들지 않는다")
    func missingModelIsRejected() {
        let settings = AISettings(
            provider: .anthropic, baseURL: "https://api.anthropic.com", model: "  "
        )
        #expect(throws: AIChatError.missingModel) {
            try AIRequestBuilder.makeRequest(
                settings: settings, apiKey: "k", systemPrompt: "s", messages: []
            )
        }
    }
}

// MARK: - 모델 목록

@Suite("AI 모델 목록")
struct AIModelCatalogTests {
    @Test("data[].id를 뽑아 정렬하고 중복을 없앤다")
    func parsesModelIDs() {
        let json = """
        {"data":[{"id":"claude-sonnet-5"},{"id":"claude-opus-5"},{"id":"claude-sonnet-5"}]}
        """
        #expect(
            AIModelCatalog.chatModels(in: Data(json.utf8)) == ["claude-opus-5", "claude-sonnet-5"]
        )
    }

    @Test("채팅에 쓸 수 없는 모델은 드롭다운에서 뺀다")
    func filtersNonChatModels() {
        let json = """
        {"data":[{"id":"gpt-4o"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},
        {"id":"dall-e-3"},{"id":"tts-1"},{"id":"omni-moderation-latest"},
        {"id":"gpt-3.5-turbo-instruct"}]}
        """
        #expect(AIModelCatalog.chatModels(in: Data(json.utf8)) == ["gpt-4o"])
    }

    @Test("Claude 모델 이름은 걸러지지 않는다", arguments: [
        "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001",
    ])
    func keepsClaudeModels(id: String) {
        #expect(AIModelCatalog.isChatModel(id))
    }

    @Test("응답이 깨졌거나 형식이 다르면 빈 목록을 준다", arguments: [
        "", "not json", "{}", #"{"data":"nope"}"#, #"{"models":[{"name":"llama3.1"}]}"#,
    ])
    func malformedResponses(body: String) {
        #expect(AIModelCatalog.chatModels(in: Data(body.utf8)).isEmpty)
    }

    @Test("목록 요청은 GET /v1/models에 채팅과 같은 인증을 쓴다")
    func modelsRequestShape() throws {
        let anthropic = try AIRequestBuilder.makeModelsRequest(
            settings: AISettings(provider: .anthropic), apiKey: "sk-test-key"
        )
        #expect(anthropic.httpMethod == "GET")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(anthropic.httpBody == nil)

        let ollama = try AIRequestBuilder.makeModelsRequest(
            settings: AISettings(provider: .ollama), apiKey: nil
        )
        #expect(ollama.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(ollama.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("모델 이름이 비어 있어도 목록은 요청할 수 있다")
    func modelsRequestNeedsNoModelName() throws {
        // 목록은 모델 이름을 모를 때 쓰는 기능이다. 이름을 요구하면 순환이 된다.
        let settings = AISettings(
            provider: .anthropic, baseURL: "https://api.anthropic.com", model: ""
        )
        let request = try AIRequestBuilder.makeModelsRequest(settings: settings, apiKey: "sk-key")
        #expect(request.url?.path == "/v1/models")
    }

    @Test("키가 필요한 제공자는 키 없이 목록도 요청하지 않는다")
    func modelsRequestNeedsKey() {
        #expect(throws: AIChatError.missingAPIKey) {
            try AIRequestBuilder.makeModelsRequest(
                settings: AISettings(provider: .anthropic), apiKey: nil
            )
        }
    }

    @Test("붙여넣은 /v1/models 경로도 흡수한다")
    func absorbsModelsPath() throws {
        let url = try AIRequestBuilder.endpointURL(
            base: "https://api.openai.com/v1/models", format: .openAIChatCompletions
        )
        #expect(url.absoluteString == "https://api.openai.com/v1/chat/completions")
    }
}

// MARK: - 스트림 해석

@Suite("AI 스트림 해석")
struct AIStreamParserTests {
    @Test("Anthropic text_delta는 본문 조각이다")
    func anthropicDelta() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"안녕"}}"#
        #expect(AIStreamParser.event(from: line, format: .anthropicMessages) == .text("안녕"))
    }

    @Test("Anthropic message_stop은 종료다")
    func anthropicStop() {
        let line = #"data: {"type":"message_stop"}"#
        #expect(AIStreamParser.event(from: line, format: .anthropicMessages) == .done)
    }

    @Test("Anthropic 오류 이벤트는 사유를 실어 실패로 만든다")
    func anthropicError() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"과부하"}}"#
        #expect(AIStreamParser.event(from: line, format: .anthropicMessages) == .failure("과부하"))
    }

    @Test("Anthropic tool 입력 조각은 본문이 아니다")
    func anthropicToolDeltaIgnored() {
        let line =
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}"#
        #expect(AIStreamParser.event(from: line, format: .anthropicMessages) == .ignored)
    }

    @Test("출력 상한에서 잘린 응답은 절단으로 알린다")
    func detectsTruncation() {
        let anthropic = #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        #expect(AIStreamParser.event(from: anthropic, format: .anthropicMessages) == .truncated)

        let normalStop = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
        #expect(AIStreamParser.event(from: normalStop, format: .anthropicMessages) == .ignored)

        let openAI = #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#
        #expect(AIStreamParser.event(from: openAI, format: .openAIChatCompletions) == .truncated)

        let openAIStop = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        #expect(AIStreamParser.event(from: openAIStop, format: .openAIChatCompletions) == .ignored)
    }

    @Test("OpenAI delta.content는 본문 조각이다")
    func openAIDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"안녕"}}]}"#
        #expect(AIStreamParser.event(from: line, format: .openAIChatCompletions) == .text("안녕"))
    }

    @Test("error가 null인 정상 조각을 실패로 뒤집지 않는다")
    func openAINullErrorIsNotFailure() {
        // JSON null은 키가 사라지지 않고 NSNull로 남는다. `as? [String: Any]`를 거치지
        // 않으면 `if let`이 성립해 정상 응답 전체가 실패가 된다.
        let line = #"data: {"error":null,"choices":[{"delta":{"content":"안녕"}}]}"#
        #expect(AIStreamParser.event(from: line, format: .openAIChatCompletions) == .text("안녕"))
    }

    @Test("OpenAI [DONE]은 종료다")
    func openAIDone() {
        #expect(AIStreamParser.event(from: "data: [DONE]", format: .openAIChatCompletions) == .done)
    }

    @Test("OpenAI 오류 본문은 실패로 만든다")
    func openAIError() {
        let line = #"data: {"error":{"message":"모델 없음","type":"invalid_request_error"}}"#
        #expect(
            AIStreamParser.event(from: line, format: .openAIChatCompletions) == .failure("모델 없음")
        )
    }

    @Test("역할만 담긴 첫 조각과 빈 content는 무시한다")
    func openAIEmptyDelta() {
        let roleOnly = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        let empty = #"data: {"choices":[{"delta":{"content":""}}]}"#
        #expect(AIStreamParser.event(from: roleOnly, format: .openAIChatCompletions) == .ignored)
        #expect(AIStreamParser.event(from: empty, format: .openAIChatCompletions) == .ignored)
    }

    @Test("data 줄이 아니거나 JSON이 깨졌으면 무시한다", arguments: [
        "event: content_block_delta", ": ping", "", "data: {깨진",
    ])
    func nonDataLines(line: String) {
        #expect(AIStreamParser.event(from: line, format: .anthropicMessages) == .ignored)
        #expect(AIStreamParser.event(from: line, format: .openAIChatCompletions) == .ignored)
    }
}

// MARK: - 네트워크 클라이언트

/// `URLProtocol` 스텁으로 응답을 흉내낸다. 실패 경로가 사용자에게 어떻게 보고되는지가
/// 이 앱에서 가장 중요한 부분이라 성공 경로만 덮고 넘기지 않는다.
@Suite("AI 클라이언트 응답 처리", .serialized)
struct AIChatClientTests {
    private let request = URLRequest(url: URL(string: "https://stub.invalid/v1/chat/completions")!)

    private func collect(
        status: Int, body: String, format: AIWireFormat = .openAIChatCompletions
    ) async throws -> [AIChatChunk] {
        let client = StubURLProtocol.makeClient(status: status, body: body)
        var chunks: [AIChatChunk] = []
        for try await chunk in client.stream(request: request, format: format) {
            chunks.append(chunk)
        }
        return chunks
    }

    @Test("정상 스트림은 조각을 순서대로 준다")
    func yieldsChunksInOrder() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"안"}}]}

        data: {"choices":[{"delta":{"content":"녕"}}]}

        data: [DONE]

        """
        let chunks = try await collect(status: 200, body: body)
        #expect(chunks == [.text("안"), .text("녕")])
    }

    @Test("HTTP 오류는 상태 코드와 서버 메시지를 함께 보고한다")
    func reportsHTTPError() async {
        let body = #"{"error":{"message":"Incorrect API key provided"}}"#
        await #expect(
            throws: AIChatError.httpStatus(code: 401, message: "Incorrect API key provided")
        ) {
            try await collect(status: 401, body: body)
        }
    }

    @Test("JSON이 아닌 오류 본문도 그대로 실어 보고한다")
    func reportsNonJSONError() async {
        await #expect(throws: AIChatError.httpStatus(code: 502, message: "Bad Gateway")) {
            try await collect(status: 502, body: "Bad Gateway")
        }
    }

    @Test("스트림 안의 오류 이벤트를 삼키지 않는다")
    func propagatesStreamError() async {
        let body = """
        data: {"type":"error","error":{"message":"과부하"}}

        """
        await #expect(throws: AIChatError.stream("과부하")) {
            try await collect(status: 200, body: body, format: .anthropicMessages)
        }
    }

    @Test("절단 신호는 조각으로 올라온다")
    func surfacesTruncation() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"안"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: [DONE]

        """
        let chunks = try await collect(status: 200, body: body)
        #expect(chunks == [.text("안"), .truncated])
    }
}

// MARK: - CLI 제공자 (개발 빌드 전용)

@Suite("CLI 제공자")
struct AICLIClientTests {
    private let messages = [
        AIChatMessage(role: .user, text: "이 화면 요약해줘"),
        AIChatMessage(role: .assistant, text: "항목 3개입니다."),
        AIChatMessage(role: .user, text: "지워도 돼?"),
    ]

    @Test("CLI 제공자는 HTTP 와이어 포맷도 API 키도 쓰지 않는다")
    func transportShape() {
        #expect(AIProvider.claudeCodeCLI.wireFormat == nil)
        #expect(AIProvider.claudeCodeCLI.cliTool == .claudeCode)
        #expect(!AIProvider.claudeCodeCLI.requiresAPIKey)
        #expect(AIProvider.anthropic.cliTool == nil)
        #expect(AIProvider.anthropic.wireFormat == .anthropicMessages)
    }

    @Test("HTTP 요청 생성기는 CLI 제공자를 거부한다")
    func httpBuilderRejectsCLIProvider() {
        let settings = AISettings(provider: .claudeCodeCLI)
        #expect(throws: AIChatError.notHTTPProvider) {
            try AIRequestBuilder.makeRequest(
                settings: settings, apiKey: nil, systemPrompt: "s", messages: []
            )
        }
        #expect(throws: AIChatError.notHTTPProvider) {
            try AIRequestBuilder.makeModelsRequest(settings: settings, apiKey: nil)
        }
    }

    @Test("대화 전체를 하나의 프롬프트로 넘긴다")
    func transcriptCarriesWholeConversation() {
        let text = AICLIClient.transcript(messages)
        #expect(text.contains("사용자: 이 화면 요약해줘"))
        #expect(text.contains("도우미: 항목 3개입니다."))
        #expect(text.hasSuffix("사용자: 지워도 돼?"))
    }

    @Test("도구는 전부 막고 MCP도 끌어오지 않는다")
    func argumentsDenyTools() {
        let arguments = AICLIClient.arguments(
            tool: .claudeCode, model: "sonnet", systemPrompt: "시스템", messages: messages
        )

        #expect(arguments.first == "-p")
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("sonnet"))
        #expect(arguments.contains("--append-system-prompt"))
        #expect(arguments.contains("시스템"))
        #expect(arguments.contains("--strict-mcp-config"))
        // 도구를 열어 두면 이 앱이 사용자 파일을 고치거나 명령을 실행하는 경로가 된다.
        #expect(arguments.contains("--disallowed-tools"))
        for tool in ["Bash", "Edit", "Write", "WebFetch", "Read"] {
            #expect(arguments.contains(tool))
        }
        // 자격증명을 인자로 넘기지 않는다. 인증은 CLI가 이미 갖고 있다.
        #expect(!arguments.contains { $0.lowercased().contains("token") })
        #expect(!arguments.contains { $0.lowercased().contains("api-key") })
    }

    @Test("실행 파일이 없으면 실행하지 않는다", arguments: ["", "   ", "/nonexistent/claude"])
    func rejectsMissingExecutable(path: String) {
        #expect(throws: AIChatError.cliNotFound(path.trimmingCharacters(in: .whitespaces))) {
            try AICLIClient.makeInvocation(
                tool: .claudeCode, executablePath: path, model: "sonnet",
                systemPrompt: "s", messages: []
            )
        }
    }

    @Test("모델이 비면 실행하지 않는다")
    func rejectsMissingModel() {
        #expect(throws: AIChatError.missingModel) {
            try AICLIClient.makeInvocation(
                tool: .claudeCode, executablePath: "/bin/echo", model: " ",
                systemPrompt: "s", messages: []
            )
        }
    }

    @Test("작업 디렉터리는 임시 디렉터리로 둔다")
    func runsInTemporaryDirectory() throws {
        let invocation = try AICLIClient.makeInvocation(
            tool: .claudeCode, executablePath: "/bin/echo", model: "sonnet",
            systemPrompt: "s", messages: messages
        )
        // 실수로 파일을 건드려도 저장소가 아니라 임시 디렉터리에서 일어나야 한다.
        #expect(invocation.workingDirectory.path == URL(
            fileURLWithPath: NSTemporaryDirectory()
        ).path)
        #expect(invocation.executable == "/bin/echo")
    }

    @Test("성공한 실행의 출력을 답변 조각으로 올린다")
    func yieldsOutput() async throws {
        let client = AICLIClient(run: { _ in ShellResult(output: "  안녕하세요\n", exitCode: 0) })
        let invocation = try AICLIClient.makeInvocation(
            tool: .claudeCode, executablePath: "/bin/echo", model: "sonnet",
            systemPrompt: "s", messages: messages
        )

        var chunks: [AIChatChunk] = []
        for try await chunk in client.stream(invocation) { chunks.append(chunk) }
        #expect(chunks == [.text("안녕하세요")])
    }

    @Test("실패한 실행은 종료 코드와 출력을 실어 보고한다")
    func reportsFailure() async throws {
        let client = AICLIClient(run: { _ in
            ShellResult(output: "Invalid API key · Please run /login", exitCode: 1)
        })
        let invocation = try AICLIClient.makeInvocation(
            tool: .claudeCode, executablePath: "/bin/echo", model: "sonnet",
            systemPrompt: "s", messages: messages
        )

        await #expect(
            throws: AIChatError.cliFailed(
                exitCode: 1, message: "Invalid API key · Please run /login"
            )
        ) {
            for try await _ in client.stream(invocation) {}
        }
    }

    @Test("출력이 비어 있으면 로그인 상태를 의심하도록 알린다")
    func reportsEmptyOutput() async throws {
        let client = AICLIClient(run: { _ in ShellResult(output: "", exitCode: 1) })
        let invocation = try AICLIClient.makeInvocation(
            tool: .claudeCode, executablePath: "/bin/echo", model: "sonnet",
            systemPrompt: "s", messages: messages
        )

        await #expect(throws: AIChatError.cliFailed(exitCode: 1, message: "출력이 없습니다. 로그인 상태를 확인하세요.")) {
            for try await _ in client.stream(invocation) {}
        }
    }
}

// MARK: - 대화 상태

@Suite("챗봇 대화 상태", .serialized)
@MainActor
struct ChatViewModelTests {
    private let localSettings = AISettings(provider: .ollama)

    private func makeViewModel(status: Int, body: String) -> ChatViewModel {
        ChatViewModel(client: StubURLProtocol.makeClient(status: status, body: body))
    }

    @Test("조각을 이어 붙여 답변 하나로 만든다")
    func appendsChunks() async {
        let body = """
        data: {"choices":[{"delta":{"content":"안"}}]}

        data: {"choices":[{"delta":{"content":"녕"}}]}

        data: [DONE]

        """
        let viewModel = makeViewModel(status: 200, body: body)
        viewModel.input = "요약해줘"
        viewModel.send(
            settings: localSettings,
            apiKey: nil,
            context: ScreenContext(title: "캐시", lines: ["항목 0개"])
        )

        #expect(await waitUntil { !viewModel.isStreaming })
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.last?.text == "안녕")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("한 조각도 못 받으면 빈 말풍선을 지우고 사유를 남긴다")
    func reportsEmptyResponse() async {
        // 2xx인데 본문에 쓸 조각이 없는 경우. 조용히 지우면 아무 일도 없었던 것처럼 보인다.
        let viewModel = makeViewModel(status: 200, body: ": ping\n\ndata: [DONE]\n\n")
        viewModel.input = "요약해줘"
        viewModel.send(
            settings: localSettings, apiKey: nil,
            context: ScreenContext(title: "캐시", lines: [])
        )

        #expect(await waitUntil { !viewModel.isStreaming })
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.role == .user)
        #expect(viewModel.errorMessage?.contains("응답을 받지 못했습니다") == true)
    }

    @Test("잘린 답변에는 잘렸다는 사실을 덧붙인다")
    func marksTruncatedAnswer() async {
        let body = """
        data: {"choices":[{"delta":{"content":"긴 답변"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: [DONE]

        """
        let viewModel = makeViewModel(status: 200, body: body)
        viewModel.input = "길게 설명해줘"
        viewModel.send(
            settings: localSettings, apiKey: nil,
            context: ScreenContext(title: "캐시", lines: [])
        )

        #expect(await waitUntil { !viewModel.isStreaming })
        #expect(viewModel.messages.last?.text.contains("길이 제한으로 잘렸습니다") == true)
    }

    @Test("HTTP 오류는 배너로 보고하고 빈 말풍선을 남기지 않는다")
    func reportsHTTPFailure() async {
        let viewModel = makeViewModel(
            status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#
        )
        viewModel.input = "요약해줘"
        viewModel.send(
            settings: localSettings, apiKey: nil,
            context: ScreenContext(title: "캐시", lines: [])
        )

        #expect(await waitUntil { !viewModel.isStreaming })
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.errorMessage?.contains("Incorrect API key") == true)
    }

    @Test("설정이 잘못되면 요청을 보내지 않고 배너만 띄운다")
    func rejectsBadSettings() {
        let viewModel = ChatViewModel()
        viewModel.input = "요약해줘"
        viewModel.send(
            settings: AISettings(provider: .anthropic),
            apiKey: nil,
            context: ScreenContext(title: "캐시", lines: [])
        )

        #expect(!viewModel.isStreaming)
        // 사용자 질문만 남고 답변 자리표시는 만들지 않는다.
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.errorMessage == AIChatError.missingAPIKey.message)
    }

    @Test("중단하면 빈 자리표시를 남기지 않는다")
    func cancelClearsPlaceholder() {
        let viewModel = ChatViewModel()
        viewModel.input = "요약해줘"
        viewModel.send(
            settings: localSettings, apiKey: nil,
            context: ScreenContext(title: "캐시", lines: [])
        )
        viewModel.cancel()

        #expect(!viewModel.isStreaming)
        #expect(viewModel.messages.allSatisfy { !$0.text.isEmpty })
    }
}

// MARK: - 마크다운 표시

@Suite("마크다운 표시")
struct MarkdownParserTests {
    private func plain(_ text: String) -> String {
        String(MarkdownParser.attributed(text).characters)
    }

    @Test("제목·글머리표·번호 목록을 블록으로 나눈다")
    func splitsBlocks() {
        let text = """
        ## 메모리 상태
        - 여유 0%
        * 스왑 38 GB
        1. 첫째
        2) 둘째
        """
        #expect(MarkdownParser.blocks(text) == [
            .heading(level: 2, text: "메모리 상태"),
            .bullet("여유 0%"),
            .bullet("스왑 38 GB"),
            .numbered(marker: "1.", text: "첫째"),
            .numbered(marker: "2.", text: "둘째"),
        ])
    }

    @Test("빈 줄로 문단을 나누고 문단 안 줄바꿈은 지킨다")
    func splitsParagraphs() {
        let text = "첫 줄\n둘째 줄\n\n다음 문단"
        #expect(MarkdownParser.blocks(text) == [
            .paragraph("첫 줄\n둘째 줄"),
            .paragraph("다음 문단"),
        ])
    }

    @Test("`#`뒤에 공백이 없으면 제목이 아니다")
    func hashTagIsNotHeading() {
        #expect(MarkdownParser.blocks("#태그") == [.paragraph("#태그")])
        #expect(MarkdownParser.blocks("####### 일곱개") == [.paragraph("####### 일곱개")])
    }

    @Test("코드 블록을 묶어 담는다")
    func collectsCodeBlock() {
        let text = "설명\n```\ndu -sk /tmp\nrm -rf x\n```\n끝"
        #expect(MarkdownParser.blocks(text) == [
            .paragraph("설명"),
            .code("du -sk /tmp\nrm -rf x"),
            .paragraph("끝"),
        ])
    }

    @Test("스트리밍 중 닫히지 않은 코드 블록도 잃지 않는다")
    func handlesUnterminatedCodeBlock() {
        // 조각이 도착하는 중에는 닫는 ```가 아직 없다. 내용을 버리면 답변이 사라진다.
        #expect(MarkdownParser.blocks("```\ndu -sk") == [.code("du -sk")])
    }

    @Test("굵게·기울임·인라인 코드 기호는 화면에 남지 않는다")
    func stripsInlineSyntax() {
        #expect(plain("**개발 데몬 정리 화면.**") == "개발 데몬 정리 화면.")
        #expect(plain("*기울임*") == "기울임")
        #expect(plain("`du -sk`") == "du -sk")
        #expect(plain("나머지는 **표시만** 가능") == "나머지는 표시만 가능")
    }

    @Test("파일 이름의 밑줄을 서식으로 먹지 않는다")
    func keepsUnderscoresInFileNames() {
        // 이 앱의 화면은 경로로 가득하다. node_modules가 "nodemodules"로 바뀌면 안 된다.
        #expect(plain("node_modules_cache") == "node_modules_cache")
        #expect(plain("DerivedData_old.zip") == "DerivedData_old.zip")
    }

    @Test("닫히지 않은 서식이 와도 글자를 잃지 않는다")
    func survivesPartialSyntax() {
        // 스트리밍 중 `**굵게`처럼 반쪽 문법이 도착한다.
        #expect(plain("**굵게").contains("굵게"))
        #expect(plain("절반 `코드").contains("코드"))
    }

    @Test("서식이 없는 답변은 문단 하나로 그린다")
    func plainAnswerStaysOneParagraph() {
        #expect(MarkdownParser.blocks("항목 3개입니다.") == [.paragraph("항목 3개입니다.")])
        #expect(MarkdownParser.blocks("") == [])
    }
}

// MARK: - 화면 컨텍스트

@Suite("화면 컨텍스트")
@MainActor
struct ScreenContextTests {
    private func makeItems(_ count: Int, selectedPrefix: Int = 0) -> [CleanableItem] {
        (0..<count).map { index in
            CleanableItem(
                name: "item-\(index)",
                path: URL(fileURLWithPath: "/tmp/item-\(index)"),
                sizeBytes: Int64(index + 1) * 1_000_000,
                isSelected: index < selectedPrefix
            )
        }
    }

    @Test("목록이 길면 상한까지만 넣고 생략 사실을 밝힌다")
    func truncatesLongLists() {
        let viewModel = CleanableListViewModel(scan: { [] })
        viewModel.items = makeItems(ScreenContext.maximumListedItems + 5)

        let context = ScreenContextBuilder.cleanableList(title: "캐시", viewModel: viewModel)
        let rows = context.lines.filter { $0.hasPrefix("- item-") }
        #expect(rows.count == ScreenContext.maximumListedItems)
        #expect(context.lines.contains { $0.contains("외 5개는 길이 제한으로 생략됨") })
    }

    @Test("선택 상태와 합계가 프롬프트에 들어간다")
    func reportsSelection() {
        let viewModel = CleanableListViewModel(scan: { [] })
        viewModel.items = makeItems(3, selectedPrefix: 2)

        let context = ScreenContextBuilder.cleanableList(title: "캐시", viewModel: viewModel)
        #expect(context.lines.contains { $0.hasPrefix("항목 3개") })
        #expect(context.lines.contains { $0.hasPrefix("선택 2개") })
        #expect(context.lines.filter { $0.hasSuffix("선택됨") }.count == 2)
        // 되돌릴 수 있는 삭제인지 아닌지는 모델이 반드시 알아야 한다.
        #expect(context.lines.contains { $0.contains("휴지통으로 이동") })
    }

    @Test("스캔 실패 배너는 컨텍스트에도 실린다")
    func includesErrorBanner() {
        let viewModel = CleanableListViewModel(scan: { [] })
        viewModel.errorMessage = "권한 부족"
        let context = ScreenContextBuilder.cleanableList(title: "캐시", viewModel: viewModel)
        #expect(context.lines.contains("오류 배너: 권한 부족"))
    }

    @Test("빈 목록은 비어 있다고 말한다")
    func emptyList() {
        let viewModel = CleanableListViewModel(scan: { [] })
        let context = ScreenContextBuilder.cleanableList(title: "캐시", viewModel: viewModel)
        #expect(context.lines.contains("목록: 비어 있음"))
    }

    @Test("등록한 스냅샷은 보내는 시점에 평가된다")
    func snapshotIsEvaluatedLate() {
        let viewModel = CleanableListViewModel(scan: { [] })
        let store = ChatContextStore()
        store.register(title: "캐시데이터") {
            ScreenContextBuilder.cleanableList(title: "캐시데이터", viewModel: viewModel)
        }

        #expect(store.current().lines.contains("목록: 비어 있음"))

        // 등록 이후에 스캔이 끝난 상황. 값으로 굳혔다면 여기서 여전히 빈 목록을 설명한다.
        viewModel.items = makeItems(2)
        #expect(store.current().lines.contains { $0.hasPrefix("항목 2개") })
    }

    @Test("등록이 없으면 없다고 말한다")
    func unregisteredStore() {
        let store = ChatContextStore()
        #expect(store.current().lines == ["표시할 화면 정보가 없습니다."])
    }

    @Test("시스템 프롬프트는 화면 스냅샷과 안전 규칙을 함께 담는다")
    func systemPromptCarriesContext() {
        let context = ScreenContext(title: "임시파일", lines: ["항목 2개, 합계 1 MB"])
        let prompt = ChatViewModel.systemPrompt(context: context)
        #expect(prompt.contains("## 현재 화면: 임시파일"))
        #expect(prompt.contains("항목 2개, 합계 1 MB"))
        #expect(prompt.contains("지어내지"))
        #expect(prompt.contains("되돌릴 수 있는지"))
    }
}

// MARK: - 설정 저장

@Suite("AI 설정 저장")
@MainActor
struct AISettingsViewModelTests {
    private let store = InMemorySettingsStore()

    @Test("저장 전에는 저장되지 않음으로, 저장 후에는 저장됨으로 표시한다")
    func tracksUnsavedChanges() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        #expect(!viewModel.hasUnsavedChanges)

        viewModel.apiKey = "sk-new"
        #expect(viewModel.hasUnsavedChanges)

        viewModel.save()
        #expect(!viewModel.hasUnsavedChanges)
        #expect(viewModel.statusMessage == "저장했습니다.")
    }

    @Test("키체인은 화면이 뜬 뒤에 읽는다")
    func loadsKeyLazily() async {
        let keyStore = InMemoryAPIKeyStore(seeded: ["anthropic": "sk-stored"])
        let viewModel = AISettingsViewModel(store: store, keyStore: keyStore)

        // init에서 키체인을 읽으면 승인 다이얼로그가 첫 창을 그리기 전에 UI를 멈춘다.
        #expect(viewModel.apiKey == "")

        await viewModel.loadKeyIfNeeded()
        #expect(viewModel.apiKey == "sk-stored")
        #expect(!viewModel.hasUnsavedChanges)
    }

    @Test("제공자별로 모델·URL·키를 따로 기억한다")
    func keepsPerProviderValues() async {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )

        viewModel.model = "claude-opus-5"
        viewModel.apiKey = "sk-anthropic"
        viewModel.save()

        viewModel.provider = .openAI
        await viewModel.loadKeyIfNeeded()
        #expect(viewModel.model == AIProvider.openAI.defaultModel)
        #expect(viewModel.apiKey == "")

        viewModel.provider = .anthropic
        await viewModel.loadKeyIfNeeded()
        #expect(viewModel.model == "claude-opus-5")
        #expect(viewModel.apiKey == "sk-anthropic")
    }

    @Test("키체인 저장 실패를 성공으로 보고하지 않는다")
    func reportsKeychainFailure() {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(alwaysFails: true)
        )
        viewModel.apiKey = "sk-new"
        viewModel.save()

        #expect(viewModel.hasUnsavedChanges)
        #expect(viewModel.statusMessage?.contains("저장하지 못했습니다") == true)
    }

    @Test("키 칸을 건드리지 않은 저장은 보관 중인 키를 지우지 않는다")
    func saveKeepsStoredKeyWhenFieldUntouched() {
        // 키체인 읽기가 거부되면 칸이 빈 상태가 된다. 그때 무조건 쓰기를 하면
        // 삭제가 통과해(읽기만 ACL이 막는다) 보관 중인 키가 영구 소실된다.
        let keyStore = InMemoryAPIKeyStore(seeded: ["anthropic": "sk-stored"])
        let viewModel = AISettingsViewModel(store: store, keyStore: keyStore)
        #expect(viewModel.apiKey == "")

        viewModel.model = "claude-opus-5"
        viewModel.save()

        #expect(keyStore.key(for: "anthropic") == "sk-stored")
    }

    @Test("사용자가 직접 비운 키는 삭제한다")
    func saveDeletesKeyWhenClearedByUser() async {
        let keyStore = InMemoryAPIKeyStore(seeded: ["anthropic": "sk-stored"])
        let viewModel = AISettingsViewModel(store: store, keyStore: keyStore)
        await viewModel.loadKeyIfNeeded()

        viewModel.apiKey = ""
        viewModel.save()

        #expect(keyStore.key(for: "anthropic") == nil)
    }

    @Test("키가 없거나 URL이 잘못되면 연결 준비 완료로 보지 않는다")
    func configurationGate() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        #expect(!viewModel.isConfigured)

        viewModel.apiKey = "sk-test"
        #expect(viewModel.isConfigured)

        viewModel.baseURL = "http://api.example.com"
        #expect(!viewModel.isConfigured)

        viewModel.baseURL = AIProvider.anthropic.defaultBaseURL
        viewModel.model = ""
        #expect(!viewModel.isConfigured)
    }

    @Test("로컬 제공자는 키 없이 준비 완료이고 요청에도 키를 싣지 않는다")
    func localProviderNeedsNoKey() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        viewModel.provider = .ollama
        #expect(viewModel.isConfigured)
        #expect(viewModel.apiKeyForRequest == nil)
    }

    @Test("모델 목록을 받아 오면 드롭다운 후보가 채워진다")
    func loadsModelOptions() async {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(),
            fetchModels: { _, _ in ["claude-opus-5", "claude-sonnet-5"] }
        )
        viewModel.apiKey = "sk-test"
        viewModel.refreshModels()

        #expect(await waitUntil { !viewModel.isLoadingModels })
        #expect(viewModel.availableModels == ["claude-opus-5", "claude-sonnet-5"])
        #expect(viewModel.statusMessage == "모델 2개를 불러왔습니다.")
    }

    @Test("목록에 없는 모델을 쓰고 있어도 선택이 사라지지 않는다")
    func keepsUnlistedModelSelectable() async {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(),
            fetchModels: { _, _ in ["claude-opus-5"] }
        )
        viewModel.apiKey = "sk-test"
        viewModel.model = "internal-gateway-model"
        viewModel.refreshModels()

        #expect(await waitUntil { !viewModel.isLoadingModels })
        #expect(viewModel.modelOptions == ["internal-gateway-model", "claude-opus-5"])
    }

    @Test("목록 조회가 실패하면 낡은 목록을 남기지 않는다")
    func clearsModelsOnFailure() async {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(),
            fetchModels: { _, _ in
                throw AIChatError.httpStatus(code: 401, message: "Incorrect API key")
            }
        )
        viewModel.apiKey = "sk-test"
        viewModel.refreshModels()

        #expect(await waitUntil { !viewModel.isLoadingModels })
        // 낡은 목록을 남기면 지금 쓸 수 없는 모델을 고르게 된다.
        #expect(viewModel.availableModels.isEmpty)
        #expect(viewModel.statusMessage?.contains("Incorrect API key") == true)
    }

    @Test("제공자를 바꾸면 이전 제공자의 모델 목록을 버린다")
    func clearsModelsOnProviderChange() async {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(),
            fetchModels: { _, _ in ["claude-opus-5"] }
        )
        viewModel.apiKey = "sk-test"
        viewModel.refreshModels()
        #expect(await waitUntil { !viewModel.availableModels.isEmpty })

        viewModel.provider = .ollama
        #expect(viewModel.availableModels.isEmpty)
    }

    @Test("목록 조회 조건은 모델 이름을 요구하지 않는다")
    func canListModelsWithoutModelName() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        viewModel.model = ""
        #expect(!viewModel.canListModels)  // 키가 없다

        viewModel.apiKey = "sk-test"
        #expect(viewModel.canListModels)  // 모델 이름은 없어도 된다
        #expect(!viewModel.isConfigured)  // 채팅은 아직 불가
    }

    @Test("CLI 제공자는 실행 파일 존재만으로 준비 완료를 판단한다")
    func cliProviderConfiguration() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        viewModel.provider = .claudeCodeCLI

        viewModel.baseURL = "/nonexistent/claude"
        #expect(!viewModel.isConfigured)

        // 자격증명은 CLI가 갖고 있다. 앱은 키를 요구하지도, 요청에 싣지도 않는다.
        viewModel.baseURL = "/bin/echo"
        #expect(viewModel.isConfigured)
        #expect(viewModel.apiKeyForRequest == nil)
    }

    @Test("CLI 제공자의 모델 목록은 네트워크 없이 채운다")
    func cliProviderModelsAreLocal() {
        let viewModel = AISettingsViewModel(
            store: store,
            keyStore: InMemoryAPIKeyStore(),
            fetchModels: { _, _ in
                Issue.record("CLI 제공자는 모델 목록을 네트워크로 묻지 않아야 한다")
                return []
            }
        )
        viewModel.provider = .claudeCodeCLI
        #expect(viewModel.canListModels)

        viewModel.refreshModels()
        #expect(viewModel.availableModels == AICLITool.claudeCode.models)
        #expect(!viewModel.isLoadingModels)
    }

    @Test("설정 화면 컨텍스트에 키 값이 새지 않는다")
    func settingsContextHidesKey() {
        let viewModel = AISettingsViewModel(
            store: store, keyStore: InMemoryAPIKeyStore()
        )
        viewModel.apiKey = "sk-super-secret"

        let context = ScreenContextBuilder.settings(viewModel: viewModel)
        #expect(!context.promptText.contains("sk-super-secret"))
        #expect(context.lines.contains { $0.hasPrefix("API 키: 입력됨") })
    }
}
