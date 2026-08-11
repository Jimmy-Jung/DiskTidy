import Foundation

/// Claude Code CLI의 `--output-format stream-json` 한 줄을 해석한다.
///
/// HTTP SSE용 `AIStreamParser`와 형식이 다르다. 여기는 `data:` 접두어가 없는 NDJSON이고,
/// CLI가 자기 진행 상황(`system`·`rate_limit_event`)까지 섞어 보낸다.
///
/// 실측한 한 응답의 줄 구성(claude 2.1.226):
/// ```
/// {"type":"system","subtype":"init",...}
/// {"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}
/// {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta",...}}}
/// {"type":"assistant","message":{"content":[{"type":"thinking",...}]}}
/// {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"1"}}}
/// {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}
/// {"type":"result","subtype":"success","is_error":false,"result":"1"}
/// ```
enum AICLIStreamParser {
    enum Event: Equatable {
        case text(String)
        case done
        /// 출력 상한에서 잘렸다. 완결된 답변과 구분하지 않으면 사용자가 잘린 줄 모른다.
        case truncated
        /// CLI가 보고한 실패. 종료 코드만으로는 로그인 만료인지 모델 이름이 틀린 것인지 모른다.
        case failure(String)
        /// 본문이 아닌 줄(진행 상황, 사고 과정, JSON이 아닌 경고 문장 등).
        case ignored
    }

    static func event(from line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // CLI는 JSON 사이에 평문 경고를 섞어 보낸다("Warning: no stdin data received...").
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignored }

        switch object["type"] as? String {
        case "stream_event":
            return streamEvent(object["event"] as? [String: Any])
        case "result":
            if object["is_error"] as? Bool == true
                || object["subtype"] as? String != "success" {
                return .failure(failureMessage(in: object))
            }
            return .done
        default:
            // `assistant`는 블록이 끝난 뒤 오는 완성본이라 델타와 겹친다. 함께 받으면
            // 답변이 두 번 붙는다. `system`·`rate_limit_event`는 본문이 아니다.
            return .ignored
        }
    }

    private static func streamEvent(_ event: [String: Any]?) -> Event {
        guard let event else { return .ignored }

        switch event["type"] as? String {
        case "content_block_delta":
            // `text_delta`만 답변이다. `thinking_delta`·`signature_delta`를 함께 받으면
            // 모델의 사고 과정이 답변 본문에 섞여 나온다.
            guard let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return .ignored }
            return .text(text)

        case "message_delta":
            // 절단 신호는 여기에만 실려 온다.
            guard let delta = event["delta"] as? [String: Any],
                  delta["stop_reason"] as? String == "max_tokens"
            else { return .ignored }
            return .truncated

        default:
            return .ignored
        }
    }

    /// 실패 사유를 꺼낸다. 실패한 `result`는 문구를 `result`나 `error` 중 한쪽에 담는다.
    private static func failureMessage(in object: [String: Any]) -> String {
        for key in ["result", "error"] {
            if let message = object[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        if let subtype = object["subtype"] as? String, !subtype.isEmpty {
            return subtype
        }
        return "알 수 없는 오류"
    }
}
