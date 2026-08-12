import Foundation

/// 설정 값에서 HTTP 요청 하나를 만든다. 순수 함수라 네트워크 없이 검증할 수 있다.
enum AIRequestBuilder {
    /// 답변 길이 상한. 화면 요약을 묻는 용도라 길 필요가 없고,
    /// Anthropic Messages API는 `max_tokens`가 필수다.
    static let maximumOutputTokens = 1024

    /// 평문 HTTP를 허용하는 루프백 호스트. `URLComponents`는 IPv6를 대괄호째 돌려주므로
    /// 비교 전에 대괄호를 벗긴다 — 벗기지 않으면 `::1`이 영원히 매칭되지 않는다.
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1",
    ]

    static func makeRequest(
        settings: AISettings,
        apiKey: String?,
        systemPrompt: String,
        messages: [AIChatMessage]
    ) throws -> URLRequest {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIChatError.missingModel }
        guard let format = settings.provider.wireFormat else { throw AIChatError.notHTTPProvider }

        let url = try endpointURL(base: settings.baseURL, format: format)

        var request = try authorizedRequest(url: url, settings: settings, apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        request.httpBody = try body(
            provider: settings.provider,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages
        )
        return request
    }

    /// 모델 목록 조회 요청. 목록은 모델 이름을 몰라도 고를 수 있게 하는 용도라
    /// `model` 값이 비어 있어도 만들 수 있어야 한다.
    static func makeModelsRequest(settings: AISettings, apiKey: String?) throws -> URLRequest {
        guard let format = settings.provider.wireFormat else { throw AIChatError.notHTTPProvider }
        let url = try endpointURL(
            base: settings.baseURL,
            format: format,
            endpointPath: AIWireFormat.modelsPath
        )
        var request = try authorizedRequest(url: url, settings: settings, apiKey: apiKey)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// 인증 헤더와 타임아웃은 채팅과 모델 목록이 같아야 한다. 두 곳에 나눠 쓰면
    /// 한쪽만 고쳐졌을 때 "채팅은 되는데 목록은 401"이 된다.
    private static func authorizedRequest(
        url: URL, settings: AISettings, apiKey: String?
    ) throws -> URLRequest {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableKey = (key?.isEmpty == false) ? key : nil
        if settings.provider.requiresAPIKey && usableKey == nil { throw AIChatError.missingAPIKey }

        var request = URLRequest(url: url)
        // 무응답 서버에 무한정 매달리지 않는다.
        request.timeoutInterval = 60

        switch settings.provider.wireFormat {
        case .none:
            throw AIChatError.notHTTPProvider
        case .anthropicMessages:
            if let usableKey { request.setValue(usableKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAIChatCompletions:
            if let usableKey {
                request.setValue("Bearer \(usableKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// 사용자가 끝 슬래시나 전체 엔드포인트 경로를 붙여도 경로가 겹치지 않게 정리한 뒤
    /// 형식별 경로를 붙인다.
    static func endpointURL(
        base: String,
        format: AIWireFormat,
        endpointPath: String? = nil
    ) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty
        else { throw AIChatError.invalidBaseURL(base) }

        // 평문 HTTP로 원격에 보내면 API 키가 그대로 노출된다. 루프백만 허용한다.
        if scheme == "http" && !isLoopback(host: host) {
            throw AIChatError.insecureEndpoint(host)
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        // 문서의 curl URL을 그대로 붙여넣는 일이 흔하다. 전체 경로를 먼저 벗긴다.
        for known in [format.path, AIWireFormat.modelsPath] where path.hasSuffix(known) {
            path.removeLast(known.count)
            break
        }
        if path.hasSuffix("/v1") { path.removeLast("/v1".count) }
        components.path = path + (endpointPath ?? format.path)

        guard let url = components.url else { throw AIChatError.invalidBaseURL(base) }
        return url
    }

    private static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return loopbackHosts.contains(normalized)
    }

    private static func body(
        provider: AIProvider,
        model: String,
        systemPrompt: String,
        messages: [AIChatMessage]
    ) throws -> Data {
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.text] }

        let payload: [String: Any]
        switch provider.wireFormat {
        case .none:
            throw AIChatError.notHTTPProvider
        case .anthropicMessages:
            payload = [
                "model": model,
                "max_tokens": maximumOutputTokens,
                "stream": true,
                "system": systemPrompt,
                "messages": turns,
            ]
        case .openAIChatCompletions:
            payload = [
                "model": model,
                outputTokenKey(for: provider): maximumOutputTokens,
                "stream": true,
                "messages": [["role": "system", "content": systemPrompt]] + turns,
            ]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// OpenAI 추론 계열 모델(o1·o3·gpt-5)은 `max_tokens`를 거부하고 400을 낸다.
    /// 모델 칸은 자유 입력이라 앱에서 우회할 수단이 없으므로 OpenAI 본가에는 새 이름을 쓴다.
    /// 호환 서버는 새 이름을 모르는 구현이 많아 기존 이름을 유지한다.
    private static func outputTokenKey(for provider: AIProvider) -> String {
        provider == .openAI ? "max_completion_tokens" : "max_tokens"
    }
}
