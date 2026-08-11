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
        // 이 셋이 다 있어야 조각 단위로 온다. 하나라도 빠지면 완료 시 한 덩어리로 온다.
        #expect(arguments.contains("stream-json"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.contains("--verbose"))
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

    /// 정해진 줄을 순서대로 흘리는 대역.
    private func makeClient(lines: [String], exitCode: Int32 = 0) -> AICLIClient {
        AICLIClient(run: { _ in
            AsyncStream { continuation in
                for line in lines { continuation.yield(.line(line)) }
                continuation.yield(.exit(exitCode))
                continuation.finish()
            }
        })
    }

    private func makeInvocation() throws -> AICLIClient.Invocation {
        try AICLIClient.makeInvocation(
            tool: .claudeCode, executablePath: "/bin/echo", model: "sonnet",
            systemPrompt: "s", messages: messages
        )
    }

    @Test("델타를 도착한 순서대로 조각으로 올린다")
    func yieldsDeltasInOrder() async throws {
        // 한 덩어리로 모아 올리면 실시간으로 써지는 효과가 사라진다.
        let client = makeClient(lines: [
            #"{"type":"system","subtype":"init"}"#,
            delta(text: "안"),
            delta(text: "녕"),
            #"{"type":"result","subtype":"success","is_error":false,"result":"안녕"}"#,
        ])

        var chunks: [AIChatChunk] = []
        for try await chunk in client.stream(try makeInvocation()) { chunks.append(chunk) }
        #expect(chunks == [.text("안"), .text("녕")])
    }

    @Test("사고 과정과 완성본은 본문에 섞지 않는다")
    func dropsThinkingAndCompletedBlocks() async throws {
        // `thinking_delta`를 받으면 모델의 사고가 답변에 나오고, `assistant`까지 받으면
        // 델타와 겹쳐 답변이 두 번 붙는다.
        let client = makeClient(lines: [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"사용자가"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"Eu"}}}"#,
            delta(text: "본문"),
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"본문"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"본문"}"#,
        ])

        var chunks: [AIChatChunk] = []
        for try await chunk in client.stream(try makeInvocation()) { chunks.append(chunk) }
        #expect(chunks == [.text("본문")])
    }

    @Test("절단 신호를 조각으로 올린다")
    func surfacesTruncation() async throws {
        let client = makeClient(lines: [
            delta(text: "긴 답변"),
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"긴 답변"}"#,
        ])

        var chunks: [AIChatChunk] = []
        for try await chunk in client.stream(try makeInvocation()) { chunks.append(chunk) }
        #expect(chunks == [.text("긴 답변"), .truncated])
    }

    @Test("CLI가 보고한 실패 사유를 그대로 실어 보고한다")
    func reportsReportedFailure() async throws {
        // 종료 코드만으로는 로그인 만료인지 모델 이름이 틀린 것인지 구분할 수 없다.
        let client = makeClient(
            lines: [
                #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key · Please run /login"}"#
            ],
            exitCode: 1
        )

        await #expect(
            throws: AIChatError.cliFailed(
                exitCode: 1, message: "Invalid API key · Please run /login"
            )
        ) {
            for try await _ in client.stream(try makeInvocation()) {}
        }
    }

    @Test("사유 없이 실패하면 로그인 상태를 의심하도록 알린다")
    func reportsBareFailure() async throws {
        let client = makeClient(lines: [], exitCode: 1)

        await #expect(throws: AIChatError.cliFailed(exitCode: 1, message: "출력이 없습니다. 로그인 상태를 확인하세요.")) {
            for try await _ in client.stream(try makeInvocation()) {}
        }
    }

    private func delta(text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(text)"}}}"#
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

// MARK: - 답변 따라 스크롤

@Suite("답변 따라 스크롤")
struct TailFollowTrackerTests {
    /// 뷰포트 400에 콘텐츠 1000, 바닥에 붙은 상태로 시작한다.
    private func makeTrackerAtBottom() -> TailFollowTracker {
        var tracker = TailFollowTracker()
        _ = tracker.update(contentHeight: 1000, contentBottom: 400, viewportHeight: 400)
        return tracker
    }

    @Test("답변이 자라면 바닥으로 따라간다")
    func growingContentFollowsTail() {
        var tracker = makeTrackerAtBottom()
        // 조각이 도착해 100 자랐다. 바닥은 아직 뷰포트 아래에 있다.
        let scrolls = tracker.update(contentHeight: 1100, contentBottom: 500, viewportHeight: 400)
        #expect(scrolls)
        #expect(tracker.followsTail)
    }

    @Test("자라면서 바닥이 밀려나는 것을 사용자 스크롤로 오해하지 않는다")
    func growthIsNotMistakenForUserScroll() {
        var tracker = makeTrackerAtBottom()
        // 임계값을 훌쩍 넘겨 밀려나도 따라가기는 유지해야 한다. 여기서 꺼지면
        // 첫 조각에 곧바로 떨어져 나머지 답변을 손으로 따라가야 한다.
        _ = tracker.update(contentHeight: 2000, contentBottom: 1400, viewportHeight: 400)
        #expect(tracker.followsTail)
    }

    @Test("사용자가 위로 스크롤하면 따라가기를 멈춘다")
    func userScrollUpStopsFollowing() {
        var tracker = makeTrackerAtBottom()
        // 높이는 그대로인데 바닥까지의 거리만 벌어졌다 = 휠·트랙패드로 올렸다.
        let scrollsOnUserScroll = tracker.update(
            contentHeight: 1000, contentBottom: 700, viewportHeight: 400
        )
        #expect(!scrollsOnUserScroll)
        #expect(!tracker.followsTail)

        // 그 뒤 답변이 더 자라도 끌려가지 않는다.
        let scrollsOnGrowth = tracker.update(
            contentHeight: 1200, contentBottom: 900, viewportHeight: 400
        )
        #expect(!scrollsOnGrowth)
    }

    @Test("바닥으로 돌아오면 다시 따라간다")
    func returningToBottomReattaches() {
        var tracker = makeTrackerAtBottom()
        _ = tracker.update(contentHeight: 1000, contentBottom: 700, viewportHeight: 400)
        #expect(!tracker.followsTail)

        // 임계값 안까지 내려왔다.
        _ = tracker.update(contentHeight: 1000, contentBottom: 410, viewportHeight: 400)
        #expect(tracker.followsTail)

        let scrolls = tracker.update(contentHeight: 1100, contentBottom: 510, viewportHeight: 400)
        #expect(scrolls)
    }

    @Test("새 질문을 보내면 따라가기를 되살린다")
    func sendingRestoresFollowing() {
        var tracker = makeTrackerAtBottom()
        _ = tracker.update(contentHeight: 1000, contentBottom: 900, viewportHeight: 400)
        #expect(!tracker.followsTail)

        tracker.followTail()
        #expect(tracker.followsTail)
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

// MARK: - 로컬 CLI 제공자 노출

@Suite("로컬 CLI 제공자 노출")
struct LocalCLIProviderExposureTests {
    @Test("끄면 CLI 제공자가 목록에서 사라진다")
    func hidesLocalCLIWhenDisabled() {
        let providers = AIProvider.selectable(includesLocalCLI: false)
        #expect(providers.allSatisfy { $0.cliTool == nil })
        #expect(!providers.contains(.claudeCodeCLI))
        #expect(!providers.contains(.codexCLI))
        #expect(providers.contains(.anthropic))
    }

    @Test("켜면 CLI 제공자가 함께 나온다")
    func showsLocalCLIWhenEnabled() {
        let providers = AIProvider.selectable(includesLocalCLI: true)
        #expect(providers.contains(.claudeCodeCLI))
        #expect(providers.contains(.codexCLI))
    }

    @Test("Codex는 모델 칸이 비어도 된다")
    func codexDoesNotRequireModel() {
        // 유효한 모델 이름이 계정 종류와 CLI 버전에 따라 달라 앱이 고를 수 없다.
        #expect(!AIProvider.codexCLI.requiresModel)
        #expect(AIProvider.claudeCodeCLI.requiresModel)
        #expect(AIProvider.anthropic.requiresModel)
    }
}

// MARK: - CLI 자식 프로세스 PATH

@Suite("CLI 자식 프로세스 PATH")
struct CLISearchPathTests {
    @Test("실행 파일이 있는 디렉터리를 맨 앞에 둔다")
    func putsExecutableDirectoryFirst() {
        // npm으로 깐 CLI는 `#!/usr/bin/env node` 셰방이라 같은 디렉터리의 node를 찾아야 한다.
        let path = AICLIClient.searchPath(forExecutableAt: "/opt/tools/bin/codex")
        #expect(path.hasPrefix("/opt/tools/bin:"))
    }

    @Test("같은 디렉터리를 두 번 넣지 않는다")
    func removesDuplicates() {
        let path = AICLIClient.searchPath(forExecutableAt: "/usr/bin/claude")
        let directories = path.split(separator: ":").map(String.init)
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!directories.contains(""))
    }
}

// MARK: - Codex 스트림 해석

@Suite("Codex 스트림 해석")
struct CodexStreamParserTests {
    private func event(_ line: String) -> AICLIStreamParser.Event {
        AICLIStreamParser.event(from: line, tool: .codex)
    }

    @Test("agent_message가 본문이다")
    func agentMessageIsAnswer() {
        let line = #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"1\n2"}}"#
        #expect(event(line) == .text("1\n2"))
    }

    @Test("item의 error는 경고이므로 실패로 올리지 않는다")
    func itemErrorIsWarning() {
        // 스킬 예산·훅 타임아웃 조정 같은 경고가 이 형태로 온다. 실패로 뒤집으면
        // 정상 응답이 오류 배너로 바뀐다(실측에서 매 요청에 두 건씩 왔다).
        let line = #"{"type":"item.completed","item":{"id":"item_1","type":"error","message":"Exceeded skills context budget."}}"#
        #expect(event(line) == .ignored)
    }

    @Test("turn.completed가 종료다")
    func turnCompletedFinishes() {
        #expect(event(#"{"type":"turn.completed","usage":{"input_tokens":10}}"#) == .done)
    }

    @Test("turn.failed의 겹싼 JSON에서 사람이 읽을 문장만 꺼낸다")
    func unwrapsNestedFailureMessage() {
        // Codex는 오류 문구 안에 JSON을 문자열로 다시 감아 넣는다. 그대로 두면
        // 배너에 이스케이프된 JSON이 나온다.
        let inner = #"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported\"}}"#
        let line = #"{"type":"turn.failed","error":{"message":"\#(inner)"}}"#
        #expect(event(line) == .failure("The 'x' model is not supported"))
    }

    @Test("최상위 error도 실패다")
    func topLevelErrorFails() {
        #expect(event(#"{"type":"error","message":"boom"}"#) == .failure("boom"))
    }

    @Test("진행 이벤트와 비JSON 줄은 무시한다")
    func ignoresNoise() {
        #expect(event(#"{"type":"thread.started","thread_id":"a"}"#) == .ignored)
        #expect(event(#"{"type":"turn.started"}"#) == .ignored)
        #expect(event("Reading additional input from stdin...") == .ignored)
    }
}

// MARK: - Codex 명령 조립

@Suite("Codex 명령 조립")
struct CodexArgumentsTests {
    private let messages = [AIChatMessage(role: .user, text: "이 화면 요약해줘")]

    @Test("읽기 전용 샌드박스로 실행하고 세션을 남기지 않는다")
    func safeDefaults() {
        let arguments = AICLIClient.arguments(
            tool: .codex, model: "", systemPrompt: "규칙", messages: messages
        )
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("--ephemeral"))
        #expect(arguments.contains("--skip-git-repo-check"))
        // 모델이 비면 넘기지 않는다. CLI 자기 설정을 쓴다.
        #expect(!arguments.contains("--model"))
        // 규칙과 대화가 한 프롬프트로 들어간다 — Codex에는 append-system-prompt가 없다.
        #expect(arguments.last?.contains("규칙") == true)
        #expect(arguments.last?.contains("이 화면 요약해줘") == true)
    }

    @Test("모델을 채우면 그대로 넘긴다")
    func passesModelWhenGiven() {
        let arguments = AICLIClient.arguments(
            tool: .codex, model: "o3", systemPrompt: "규칙", messages: messages
        )
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("o3"))
    }

    @Test("Codex는 모델 없이도 실행을 만들고 Claude는 거부한다")
    func modelRequirementFollowsTool() throws {
        let invocation = try AICLIClient.makeInvocation(
            tool: .codex, executablePath: "/bin/echo", model: " ",
            systemPrompt: "s", messages: messages
        )
        #expect(invocation.tool == .codex)
        #expect(!invocation.searchPath.isEmpty)

        #expect(throws: AIChatError.missingModel) {
            try AICLIClient.makeInvocation(
                tool: .claudeCode, executablePath: "/bin/echo", model: " ",
                systemPrompt: "s", messages: messages
            )
        }
    }
}

// MARK: - 항목 설명

@Suite("항목 설명", .serialized)
@MainActor
struct ItemExplanationStoreTests {
    private let item = CleanableItem(
        name: "Gradle 캐시",
        path: URL(fileURLWithPath: "/tmp/disktidy-gradle"),
        sizeBytes: 5_000_000_000,
        modifiedDate: nil
    )
    private let localSettings = AISettings(provider: .ollama)

    private var subject: ExplanationSubject {
        ExplanationSubject(item: item, action: "휴지통으로 이동 (되돌릴 수 있음)")
    }

    private func makeStore(body: String, status: Int = 200) -> ItemExplanationStore {
        ItemExplanationStore(client: StubURLProtocol.makeClient(status: status, body: body))
    }

    private var answerBody: String {
        """
        data: {"choices":[{"delta":{"content":"빌드 캐시입니다."}}]}

        data: [DONE]

        """
    }

    @Test("항목을 대상으로 옮길 때 경로를 캐시 키로 쓴다")
    func subjectKeysOnPath() {
        // `CleanableItem.id`는 매번 새로 만드는 UUID라서 id로 캐시하면 새로고침마다
        // 같은 폴더를 다시 물어본다.
        let rescanned = CleanableItem(name: item.name, path: item.path, sizeBytes: 1)
        #expect(subject.key == item.path.path)
        #expect(ExplanationSubject(item: rescanned, action: "삭제").key == subject.key)
        #expect(rescanned.id != item.id)
    }

    @Test("질문에 화면과 항목 사실을 담는다")
    func questionCarriesFacts() {
        let question = ItemExplanationStore.question(for: subject, screenTitle: "Android 캐시")
        #expect(question.contains("화면: Android 캐시"))
        #expect(question.contains("항목: Gradle 캐시"))
        #expect(question.contains("/tmp/disktidy-gradle"))
        // 정리 방식을 알려 주지 않으면 되돌릴 수 있는지를 모델이 지어낸다.
        #expect(question.contains("휴지통으로 이동 (되돌릴 수 있음)"))
        // 수정일이 없으면 그 줄을 넣지 않는다. 빈 값을 넣으면 모델이 그것을 근거로 삼는다.
        #expect(!question.contains("마지막 수정"))
    }

    @Test("무엇인지를 먼저 답하게 지시한다")
    func systemPromptAsksWhatItIsFirst() {
        // 잃는 것을 먼저 쓰게 하면 정작 이게 무엇인지가 뒤로 밀려, 사용자는 처음 보는
        // 이름을 그대로 둔 채 위험 문구만 읽게 된다.
        let prompt = ItemExplanationStore.systemPrompt
        let whatItIs = try? #require(prompt.range(of: "무엇인지"))
        let recoverable = prompt.range(of: "다시 만들어지는지")
        #expect(whatItIs != nil)
        #expect(recoverable != nil)
        if let whatItIs, let recoverable {
            #expect(whatItIs.lowerBound < recoverable.lowerBound)
        }
    }

    @Test("빠른 모델이 있으면 그것으로 바꿔 보낸다")
    func usesFastModel() {
        #expect(AISettings(provider: .claudeCodeCLI).usingFastModel().model == "haiku")
        // 이름을 앱이 확인할 수 없는 제공자는 사용자가 고른 모델을 그대로 쓴다 —
        // 틀린 모델 ID를 하드코딩하면 설명이 통째로 실패한다.
        let http = AISettings(
            provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-5"
        )
        #expect(http.usingFastModel().model == "claude-sonnet-5")
        #expect(AISettings(provider: .codexCLI).usingFastModel().model.isEmpty)
    }

    @Test("설명을 받아 키로 캐시한다")
    func cachesByKey() async {
        let store = makeStore(body: answerBody)
        store.explain(subject, screenTitle: "Android 캐시", settings: localSettings, apiKey: nil)

        #expect(await waitUntil { store.state(for: subject) == .ready("빌드 캐시입니다.") })

        // 다시 물어도 캐시가 그대로 남는다.
        store.explain(subject, screenTitle: "Android 캐시", settings: localSettings, apiKey: nil)
        #expect(store.state(for: subject) == .ready("빌드 캐시입니다."))
    }

    @Test("잊으면 다시 물을 수 있다")
    func forgetClearsCache() async {
        let store = makeStore(body: answerBody)
        store.explain(subject, screenTitle: "Android 캐시", settings: localSettings, apiKey: nil)
        #expect(await waitUntil { store.state(for: subject) != nil })

        store.forget(subject)
        #expect(store.state(for: subject) == nil)
    }

    @Test("실패는 사유를 남긴다")
    func reportsFailure() async {
        let store = makeStore(body: #"{"error":{"message":"Incorrect API key"}}"#, status: 401)
        store.explain(subject, screenTitle: "Android 캐시", settings: localSettings, apiKey: nil)

        #expect(await waitUntil {
            if case .failed(let message) = store.state(for: subject) {
                return message.contains("Incorrect API key")
            }
            return false
        })
    }

    @Test("설정이 잘못되면 요청을 만들지 않고 사유를 남긴다")
    func rejectsBadSettings() {
        let store = ItemExplanationStore()
        store.explain(
            subject,
            screenTitle: "Android 캐시",
            settings: AISettings(provider: .anthropic),
            apiKey: nil
        )
        if case .failed(let message) = store.state(for: subject) {
            #expect(message == AIChatError.missingAPIKey.message)
        } else {
            Issue.record("실패 상태여야 한다")
        }
    }
}
