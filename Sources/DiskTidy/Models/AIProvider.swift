import Foundation

/// 요청 본문과 응답 스트림의 형식. 지원 제공자는 여럿이지만 실제 와이어 포맷은 둘뿐이라
/// 제공자마다 클라이언트를 따로 두지 않는다.
enum AIWireFormat: Sendable {
    /// 모델 목록 경로. Anthropic과 OpenAI 모두 같은 경로에 `{"data":[{"id":…}]}`를 준다.
    static let modelsPath = "/v1/models"

    case anthropicMessages
    case openAIChatCompletions

    /// API 루트에 붙일 경로. 설정에는 버전 경로를 뺀 루트만 저장한다.
    var path: String {
        switch self {
        case .anthropicMessages: return "/v1/messages"
        case .openAIChatCompletions: return "/v1/chat/completions"
        }
    }
}

/// 이미 로그인된 공식 CLI를 그대로 실행하는 방식.
///
/// **토큰을 읽거나 헤더를 위장하지 않는다.** 구독 OAuth 토큰을 꺼내 HTTP API에 붙이는 것은
/// 제공자가 서버에서 차단하는 패턴이고 계정 정지 사유다. 여기서는 사용자가 터미널에서
/// 직접 치는 것과 같은 명령을 같은 자격증명으로 실행할 뿐이다.
enum AICLITool: String, CaseIterable, Sendable {
    case claudeCode

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code CLI"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        }
    }

    /// GUI로 실행한 앱의 `PATH`는 `/usr/bin:/bin:/usr/sbin:/sbin`뿐이라 CLI를 찾지 못한다.
    /// 흔한 설치 위치를 훑어 기본값을 정하고, 못 찾으면 사용자가 직접 고친다.
    var candidatePaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claudeCode:
            return [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        }
    }

    /// 드롭다운에 넣을 모델. CLI는 별칭을 받으며 릴리스마다 바뀌지 않는다.
    var models: [String] {
        switch self {
        case .claudeCode: return ["sonnet", "opus", "haiku"]
        }
    }

    var defaultExecutablePath: String {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? candidatePaths[0]
    }
}

/// 요청을 어디로 보내는가. HTTP API와 로컬 CLI는 인증·전송이 완전히 다르다.
enum AITransport: Sendable {
    case http(AIWireFormat)
    case localCLI(AICLITool)
}

/// 연결할 AI Agent 제공자.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI
    case ollama
    case openAICompatible
    /// 개발 빌드 전용. 구독 계정으로 이미 로그인된 CLI를 그대로 쓴다.
    case claudeCodeCLI

    var id: String { rawValue }

    /// 설정 화면에 노출할 제공자. CLI 제공자는 개발 빌드에서만 고를 수 있다 —
    /// 배포판이 사용자 구독으로 요청을 대행하는 것은 제공자 약관이 금지한다.
    static var selectable: [AIProvider] {
        #if DEBUG
        return allCases
        #else
        return allCases.filter { if case .localCLI = $0.transport { return false } else { return true } }
        #endif
    }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .ollama: return "Ollama (로컬)"
        case .openAICompatible: return "OpenAI 호환 (직접 입력)"
        case .claudeCodeCLI: return "Claude Code CLI · 구독 로그인 (개발 빌드 전용)"
        }
    }

    var transport: AITransport {
        switch self {
        case .anthropic: return .http(.anthropicMessages)
        case .openAI, .ollama, .openAICompatible: return .http(.openAIChatCompletions)
        case .claudeCodeCLI: return .localCLI(.claudeCode)
        }
    }

    /// HTTP 제공자의 와이어 포맷. CLI 제공자에는 없다.
    var wireFormat: AIWireFormat? {
        if case .http(let format) = transport { return format }
        return nil
    }

    var cliTool: AICLITool? {
        if case .localCLI(let tool) = transport { return tool }
        return nil
    }

    /// HTTP 제공자는 버전 경로(`/v1`)를 뺀 루트, CLI 제공자는 실행 파일 경로.
    /// 한 필드를 공유하는 이유는 저장·표시 경로를 둘로 늘릴 이유가 없기 때문이다.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com"
        case .ollama: return "http://localhost:11434"
        case .openAICompatible: return ""
        case .claudeCodeCLI: return AICLITool.claudeCode.defaultExecutablePath
        }
    }

    /// 제공자가 모델 이름을 바꾸면 이 값은 낡는다. 설정 화면에서 직접 고칠 수 있게 둔다.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAI: return "gpt-4o"
        case .ollama: return "llama3.1"
        case .openAICompatible: return ""
        case .claudeCodeCLI: return "sonnet"
        }
    }

    /// 로컬 제공자는 키가 없다. 설정 화면에서 키 입력을 숨기고 검증에서도 뺀다.
    /// CLI 제공자는 CLI가 이미 로그인돼 있으므로 앱이 자격증명을 만지지 않는다.
    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openAI, .openAICompatible: return true
        case .ollama, .claudeCodeCLI: return false
        }
    }

    /// 설정 화면의 첫 필드 라벨. 전송 방식에 따라 뜻이 달라진다.
    var endpointFieldLabel: String {
        switch transport {
        case .http: return "API 루트 URL"
        case .localCLI: return "CLI 실행 파일 경로"
        }
    }
}

/// 요청 하나를 만드는 데 필요한 설정 값. API 키는 여기 넣지 않는다 —
/// 키는 키체인에만 두고 요청을 만드는 순간에만 따로 건네받는다.
struct AISettings: Equatable, Sendable {
    var provider: AIProvider
    var baseURL: String
    var model: String

    init(provider: AIProvider, baseURL: String, model: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
    }

    init(provider: AIProvider) {
        self.init(
            provider: provider,
            baseURL: provider.defaultBaseURL,
            model: provider.defaultModel
        )
    }
}
