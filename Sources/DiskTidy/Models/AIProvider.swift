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
    case codex

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code CLI"
        case .codex: return "Codex CLI"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// GUI로 실행한 앱의 `PATH`는 `/usr/bin:/bin:/usr/sbin:/sbin`뿐이라 CLI를 찾지 못한다.
    /// 흔한 설치 위치를 훑어 기본값을 정하고, 못 찾으면 사용자가 직접 고친다.
    var candidatePaths: [String] {
        let home = NSHomeDirectory()
        let fixed = [
            "\(home)/.local/bin/\(executableName)",
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "\(home)/.npm-global/bin/\(executableName)",
            "\(home)/.volta/bin/\(executableName)",
        ]
        // nvm은 버전 디렉터리 안에 실행 파일을 둔다. 정적 목록으로 못 잡아 직접 훑는다.
        return fixed + Self.nodeVersionManagerPaths(for: executableName)
    }

    /// 드롭다운에 넣을 모델.
    ///
    /// Codex는 비워 둔다. 유효한 모델 집합이 계정 종류(ChatGPT 로그인 여부)와 CLI 버전에
    /// 따라 달라서, 사용자가 `~/.codex/config.toml`에 이미 골라 둔 값을 앱이 덮어쓰지 않고
    /// 그대로 쓴다 — 실측에서 흔한 이름(`gpt-5-codex`)조차 거부됐다.
    var models: [String] {
        switch self {
        case .claudeCode: return ["sonnet", "opus", "haiku"]
        case .codex: return []
        }
    }

    /// 모델 이름을 반드시 받아야 하는지. Codex는 CLI 자기 설정을 쓰므로 비워도 된다.
    var requiresModel: Bool {
        switch self {
        case .claudeCode: return true
        case .codex: return false
        }
    }

    var defaultExecutablePath: String {
        let paths = candidatePaths
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? paths[0]
    }

    /// `~/.nvm/versions/node/<버전>/bin/<이름>`을 최신 버전처럼 보이는 순서로 돌려준다.
    /// 문자열 내림차순이라 semver 정렬은 아니지만 실행 가능한 것을 찾는 데는 충분하다.
    private static func nodeVersionManagerPaths(for name: String) -> [String] {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted(by: >).map { "\(root)/\($0)/bin/\(name)" }
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
    case openAICompatible
    /// 구독 계정으로 이미 로그인된 CLI를 그대로 쓴다. 기본으로 숨어 있고 사용자가 켠다.
    case claudeCodeCLI
    case codexCLI

    var id: String { rawValue }

    /// 설정 화면에 노출할 제공자.
    ///
    /// CLI 제공자는 기본으로 숨는다. 앱이 자격증명을 만지지는 않지만, 내 구독으로 앱이
    /// 요청을 내보내는 형태이므로 사용자가 명시적으로 켜야 한다.
    static func selectable(includesLocalCLI: Bool) -> [AIProvider] {
        guard !includesLocalCLI else { return allCases }
        return allCases.filter { $0.cliTool == nil }
    }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI 호환 (직접 입력)"
        case .claudeCodeCLI: return "Claude Code CLI · 구독 로그인"
        case .codexCLI: return "Codex CLI · 구독 로그인"
        }
    }

    var transport: AITransport {
        switch self {
        case .anthropic: return .http(.anthropicMessages)
        case .openAI, .openAICompatible: return .http(.openAIChatCompletions)
        case .claudeCodeCLI: return .localCLI(.claudeCode)
        case .codexCLI: return .localCLI(.codex)
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
        case .openAICompatible: return ""
        case .claudeCodeCLI, .codexCLI: return cliTool?.defaultExecutablePath ?? ""
        }
    }

    /// 제공자가 모델 이름을 바꾸면 이 값은 낡는다. 설정 화면에서 직접 고칠 수 있게 둔다.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAI: return "gpt-4o"
        case .openAICompatible: return ""
        case .claudeCodeCLI: return "sonnet"
        // 비워 둔다. Codex는 자기 설정의 모델을 쓴다.
        case .codexCLI: return ""
        }
    }

    /// CLI 제공자는 키가 없다 — CLI가 이미 로그인돼 있어 앱이 자격증명을 만지지 않는다.
    /// 설정 화면에서 키 입력을 숨기고 검증에서도 뺀다.
    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openAI, .openAICompatible: return true
        case .claudeCodeCLI, .codexCLI: return false
        }
    }

    /// 모델 이름이 반드시 있어야 하는지. CLI 제공자는 도구가 정한다.
    var requiresModel: Bool {
        cliTool?.requiresModel ?? true
    }

    /// 짧은 설명처럼 값싸게 끝내야 하는 요청에 쓸 모델.
    ///
    /// `nil`이면 사용자가 고른 모델을 그대로 쓴다. 이름을 앱이 확인할 수 없는 제공자에
    /// 특정 모델 ID를 하드코딩하지 않는다 — 제공자가 이름을 바꾸거나 계정이 그 모델을
    /// 못 쓰면 설명이 통째로 실패한다. CLI 별칭은 릴리스마다 바뀌지 않아 안전하다.
    var fastModel: String? {
        switch self {
        case .claudeCodeCLI: return "haiku"
        case .anthropic, .openAI, .openAICompatible, .codexCLI: return nil
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

    /// 값싼 요청용으로 모델만 바꾼 사본. 바꿀 모델이 없으면 그대로 돌려준다.
    func usingFastModel() -> AISettings {
        guard let fast = provider.fastModel else { return self }
        return AISettings(provider: provider, baseURL: baseURL, model: fast)
    }
}
