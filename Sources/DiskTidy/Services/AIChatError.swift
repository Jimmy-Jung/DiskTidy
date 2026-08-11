import Foundation

/// 챗봇 요청이 실패하는 모든 경우. 배너에 그대로 띄우므로 문구까지 여기서 정한다.
enum AIChatError: Error, Equatable {
    case missingAPIKey
    case missingModel
    case invalidBaseURL(String)
    /// 평문 HTTP로 원격 호스트에 키를 보내려는 설정. 로컬 주소만 허용한다.
    case insecureEndpoint(String)
    case httpStatus(code: Int, message: String)
    /// 서버가 스트림 안에서 오류 이벤트를 보낸 경우.
    case stream(String)
    /// HTTP 전용 경로에 CLI 제공자가 들어온 경우. 호출 순서가 잘못됐다는 신호다.
    case notHTTPProvider
    case cliNotFound(String)
    case cliFailed(exitCode: Int32, message: String)

    var message: String {
        switch self {
        case .missingAPIKey:
            return "API 키가 없습니다. 설정 탭에서 키를 입력하고 저장하세요."
        case .missingModel:
            return "모델 이름이 비어 있습니다. 설정 탭에서 모델을 입력하세요."
        case .invalidBaseURL(let url):
            return "API 루트 URL이 올바르지 않습니다: \(url)"
        case .insecureEndpoint(let host):
            return "\(host)은(는) 평문 HTTP라 API 키를 보낼 수 없습니다. HTTPS를 쓰거나 localhost를 사용하세요."
        case .httpStatus(let code, let message):
            return "요청이 거부되었습니다 (HTTP \(code)). \(message)"
        case .stream(let message):
            return "응답 중 오류가 발생했습니다: \(message)"
        case .notHTTPProvider:
            return "이 제공자는 HTTP API를 쓰지 않습니다."
        case .cliNotFound(let path):
            return "CLI를 찾을 수 없습니다: \(path). 설정 탭에서 실행 파일 경로를 확인하세요."
        case .cliFailed(let exitCode, let message):
            return "CLI가 실패했습니다 (종료 코드 \(exitCode)). \(message)"
        }
    }

    /// 네트워크 오류처럼 `AIChatError`가 아닌 것도 같은 배너로 보여 준다.
    static func describe(_ error: Error) -> String {
        if let chatError = error as? AIChatError { return chatError.message }
        return "요청에 실패했습니다: \(error.localizedDescription)"
    }
}
