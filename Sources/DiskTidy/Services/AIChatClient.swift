import Foundation

/// 스트림에서 올라오는 조각. 절단 사실을 문구가 아니라 값으로 올려 UI 문구는 ViewModel에 둔다.
enum AIChatChunk: Equatable, Sendable {
    case text(String)
    case truncated
}

/// 응답을 조각 단위로 흘려 준다. 완성까지 기다리면 수십 초 동안 화면이 멈춘 것처럼 보인다.
struct AIChatClient {
    /// 오류 본문을 읽을 때의 상한. 서버가 스트림을 계속 흘려도 여기서 멈춘다.
    private static let maximumErrorBodyBytes = 8 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stream(
        request: URLRequest, format: AIWireFormat
    ) -> AsyncThrowingStream<AIChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // 상태 코드만 보고하면 키가 틀렸는지 모델이 없는지 구분할 수 없다.
                        let message = await Self.errorMessage(from: bytes)
                        throw AIChatError.httpStatus(code: http.statusCode, message: message)
                    }

                    for try await line in bytes.lines {
                        switch AIStreamParser.event(from: line, format: format) {
                        case .text(let chunk):
                            continuation.yield(.text(chunk))
                        case .truncated:
                            continuation.yield(.truncated)
                        case .done:
                            continuation.finish()
                            return
                        case .failure(let message):
                            throw AIChatError.stream(message)
                        case .ignored:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // 사용자가 중단한 것은 오류가 아니다.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 오류 응답 본문에서 사람이 읽을 문장을 꺼낸다. 실패해도 상태 코드는 남으므로 던지지 않는다.
    private static func errorMessage(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maximumErrorBodyBytes { break }
            }
        } catch {
            return "응답 본문을 읽지 못했습니다."
        }

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
