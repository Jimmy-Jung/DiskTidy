import Foundation

/// 제공자에서 쓸 수 있는 모델 목록을 받아 온다.
///
/// 모델 이름을 손으로 적게 하면 오타 한 글자에 요청 전체가 400으로 죽고, 사용자는
/// 무엇이 틀렸는지 알 수 없다. 두 와이어 포맷 모두 `GET /v1/models`에
/// `{"data":[{"id": "..."}]}`를 돌려주므로 해석은 한 곳으로 끝난다.
enum AIModelCatalog {
    /// 채팅에 쓸 수 없는 모델. OpenAI는 임베딩·음성·이미지·모더레이션 모델까지
    /// 같은 목록에 담아 주는데, 드롭다운에 섞이면 고르는 순간 요청이 실패한다.
    private static let excludedFragments = [
        "embedding", "whisper", "tts", "dall-e", "moderation",
        "audio", "realtime", "image", "babbage", "davinci", "instruct",
    ]

    static func fetch(
        settings: AISettings, apiKey: String?, session: URLSession = .shared
    ) async throws -> [String] {
        let request = try AIRequestBuilder.makeModelsRequest(settings: settings, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 상태 코드만 보고하면 키가 틀렸는지 경로가 틀렸는지 구분할 수 없다.
            throw AIChatError.httpStatus(code: http.statusCode, message: errorMessage(in: data))
        }
        return chatModels(in: data)
    }

    /// 순수 함수. 네트워크 없이 검증한다.
    static func chatModels(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else { return [] }

        let ids = entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return Array(Set(ids.filter(isChatModel))).sorted()
    }

    static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !excludedFragments.contains { lowered.contains($0) }
    }

    private static func errorMessage(in data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "응답 본문이 비어 있습니다." : text
    }
}
