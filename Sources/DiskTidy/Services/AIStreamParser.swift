import Foundation

/// SSE(Server-Sent Events) 한 줄을 해석한다. 순수 함수라 네트워크 없이 검증할 수 있다.
enum AIStreamParser {
    enum Event: Equatable {
        case text(String)
        case done
        /// 출력 상한에서 잘렸다. 완결된 답변과 구분하지 않으면 사용자가 잘린 줄 모른다.
        case truncated
        /// 서버가 스트림 안에서 보낸 오류. 무시하면 답변이 그냥 끊긴 것처럼 보인다.
        case failure(String)
        /// 이 형식이 쓰지 않는 이벤트(ping, 주석, 빈 줄 등).
        case ignored
    }

    static func event(from line: String, format: AIWireFormat) -> Event {
        guard line.hasPrefix("data:") else { return .ignored }

        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .ignored }
        if payload == "[DONE]" { return .done }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignored }

        switch format {
        case .anthropicMessages: return anthropicEvent(object)
        case .openAIChatCompletions: return openAIEvent(object)
        }
    }

    private static func anthropicEvent(_ object: [String: Any]) -> Event {
        switch object["type"] as? String {
        case "error":
            return .failure(errorMessage(in: object["error"]))
        case "message_stop":
            return .done
        case "message_delta":
            // 절단 신호는 여기에만 실려 온다. 버리면 잘린 답변이 완결된 답변처럼 보인다.
            if let delta = object["delta"] as? [String: Any],
               delta["stop_reason"] as? String == "max_tokens" {
                return .truncated
            }
            return .ignored
        default:
            break
        }
        // content_block_delta의 text_delta만 본문이다. tool 입력(partial_json)에는 text가 없다.
        guard let delta = object["delta"] as? [String: Any],
              let text = delta["text"] as? String
        else { return .ignored }
        return .text(text)
    }

    private static func openAIEvent(_ object: [String: Any]) -> Event {
        // `as? [String: Any]`를 반드시 거친다. JSON null은 키가 사라지지 않고 NSNull로 남아
        // `if let object["error"]`가 성립해 버린다. `"error": null`을 함께 보내는
        // OpenAI 호환 서버의 정상 응답이 전부 실패로 뒤집힌다.
        if let error = object["error"] as? [String: Any] {
            return .failure(errorMessage(in: error))
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first
        else { return .ignored }

        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return .text(content)
        }
        if first["finish_reason"] as? String == "length" { return .truncated }
        return .ignored
    }

    private static func errorMessage(in value: Any?) -> String {
        guard let object = value as? [String: Any],
              let message = object["message"] as? String,
              !message.isEmpty
        else { return "알 수 없는 오류" }
        return message
    }
}
