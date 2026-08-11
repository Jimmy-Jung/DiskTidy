import Foundation

/// 설정 탭의 상태. 제공자·루트 URL·모델은 UserDefaults에, API 키는 키체인에 둔다.
///
/// 값은 제공자별로 따로 저장한다. 제공자를 바꿨다가 되돌렸을 때 모델과 키를 다시
/// 입력해야 하면 설정 화면이 사실상 쓸모없어진다.
@MainActor
final class AISettingsViewModel: ObservableObject {
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            store.setString(provider.rawValue, forKey: Self.providerKey)
            loadFields(for: provider)
            Task { await loadKeyIfNeeded() }
        }
    }

    /// 로컬 CLI 제공자를 목록에 노출할지. 기본은 꺼짐.
    ///
    /// 앱이 자격증명을 만지지는 않지만, 내 구독으로 앱이 요청을 내보내는 형태다. 켜는
    /// 판단은 사용자가 한다. 껐을 때 이미 CLI 제공자를 쓰고 있었다면 첫 HTTP 제공자로
    /// 되돌린다 — 목록에서 사라진 값을 그대로 두면 설정 화면에 빈 선택이 남는다.
    @Published var isLocalCLIEnabled: Bool {
        didSet {
            guard isLocalCLIEnabled != oldValue else { return }
            store.setString(isLocalCLIEnabled ? "1" : "0", forKey: Self.localCLIEnabledKey)
            if !isLocalCLIEnabled, provider.cliTool != nil {
                provider = Self.fallbackProvider
            }
        }
    }

    @Published var baseURL: String = ""
    @Published var model: String = ""
    /// 화면에 떠 있는 키. 저장을 눌러야 키체인에 들어간다.
    @Published var apiKey: String = ""

    @Published private(set) var statusMessage: String?
    @Published private(set) var isTesting = false

    /// 제공자에서 받아 온 모델 목록. 비어 있으면 설정 화면이 직접 입력으로 떨어진다.
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isLoadingModels = false

    private let store: SettingsStore
    private let keyStore: APIKeyStore
    private let client: AIChatClient
    private let cliClient: AICLIClient
    private let fetchModels: @Sendable (AISettings, String?) async throws -> [String]

    /// 마지막으로 저장한 값. "저장되지 않음" 표시의 기준이다.
    private var savedSnapshot: Snapshot

    /// 키체인을 이미 읽었는지. 설정 탭과 챗봇 패널이 동시에 요청하므로 재진입을 막는다.
    private var isKeyLoaded = false

    private struct Snapshot: Equatable {
        let baseURL: String
        let model: String
        let apiKey: String
    }

    private static let providerKey = "AI.provider"
    private static let localCLIEnabledKey = "AI.localCLIEnabled"

    /// CLI 제공자를 끌 때 돌아갈 자리.
    private static let fallbackProvider = AIProvider.anthropic

    /// 드롭다운에 넣을 제공자.
    var selectableProviders: [AIProvider] {
        AIProvider.selectable(includesLocalCLI: isLocalCLIEnabled)
    }

    init(
        store: SettingsStore = UserDefaultsSettingsStore(),
        keyStore: APIKeyStore = KeychainAPIKeyStore(),
        client: AIChatClient = AIChatClient(),
        cliClient: AICLIClient = AICLIClient(),
        fetchModels: @escaping @Sendable (AISettings, String?) async throws -> [String] = {
            try await AIModelCatalog.fetch(settings: $0, apiKey: $1)
        }
    ) {
        self.store = store
        self.keyStore = keyStore
        self.client = client
        self.cliClient = cliClient
        self.fetchModels = fetchModels

        // `didSet`은 init 안에서 불리지 않는다. 첫 값은 직접 채운다.
        let enabled = store.string(forKey: Self.localCLIEnabledKey) == "1"
        isLocalCLIEnabled = enabled

        let saved = store.string(forKey: Self.providerKey).flatMap(AIProvider.init(rawValue:))
        // CLI 제공자를 껐는데 그 값이 저장돼 있으면 고를 수 없는 상태로 남는다.
        let selectable = AIProvider.selectable(includesLocalCLI: enabled)
        let stored = saved.flatMap { selectable.contains($0) ? $0 : nil } ?? Self.fallbackProvider
        provider = stored

        // `didSet`은 init 안에서 불리지 않는다. 첫 값은 직접 채운다.
        let loadedBaseURL = store.string(forKey: Self.baseURLKey(stored))
            ?? stored.defaultBaseURL
        let loadedModel = store.string(forKey: Self.modelKey(stored)) ?? stored.defaultModel
        baseURL = loadedBaseURL
        model = loadedModel
        // 키체인은 여기서 읽지 않는다. `SecItemCopyMatching`은 동기 호출이고 접근 승인
        // 다이얼로그가 뜨면 첫 창이 그려지기 전에 메인 스레드가 그 안에서 멈춘다.
        // 화면이 뜬 뒤 `loadKeyIfNeeded()`가 배경에서 읽어 채운다.
        apiKey = ""
        savedSnapshot = Snapshot(baseURL: loadedBaseURL, model: loadedModel, apiKey: "")
    }

    /// 키체인에서 현재 제공자의 키를 배경에서 읽어 온다. 화면이 뜬 뒤에 부른다.
    func loadKeyIfNeeded() async {
        guard !isKeyLoaded else { return }
        isKeyLoaded = true

        let keyStore = self.keyStore
        let account = provider.rawValue
        let loaded = await Task.detached { keyStore.key(for: account) }.value ?? ""

        // 읽는 동안 사용자가 직접 입력했거나 제공자를 바꿨으면 덮어쓰지 않는다.
        guard apiKey.isEmpty, account == provider.rawValue else { return }
        apiKey = loaded
        savedSnapshot = Snapshot(baseURL: baseURL, model: model, apiKey: loaded)
    }

    // MARK: - 파생 상태

    var settings: AISettings {
        AISettings(provider: provider, baseURL: baseURL, model: model)
    }

    /// 요청에 쓸 키. 로컬 제공자는 키가 없다.
    var apiKeyForRequest: String? {
        provider.requiresAPIKey ? apiKey : nil
    }

    /// 채팅을 보낼 수 있는 상태인지. 실패할 요청을 보내고 오류를 띄우는 대신 미리 막는다.
    var isConfigured: Bool {
        // Codex CLI는 자기 설정의 모델을 쓰므로 모델 칸이 비어도 된다.
        if provider.requiresModel,
           model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        switch provider.transport {
        case .http(let format):
            let endpoint = try? AIRequestBuilder.endpointURL(
                base: baseURL,
                format: format,
                allowsLANPlaintext: !provider.requiresAPIKey
            )
            guard endpoint != nil else { return false }
            if provider.requiresAPIKey {
                return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .localCLI:
            // 자격증명은 CLI가 갖고 있다. 앱이 확인할 것은 실행 파일 존재 여부뿐이다.
            return FileManager.default.isExecutableFile(
                atPath: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    var hasUnsavedChanges: Bool {
        savedSnapshot != Snapshot(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    /// 모델 목록을 요청할 수 있는 상태인지. 목록 조회에는 모델 이름이 필요 없으므로
    /// `isConfigured`보다 조건이 느슨하다.
    var canListModels: Bool {
        if provider.cliTool != nil { return true }
        let endpoint = try? AIRequestBuilder.makeModelsRequest(
            settings: settings, apiKey: apiKeyForRequest
        )
        return endpoint != nil
    }

    /// 드롭다운에 넣을 목록. 받아 온 목록에 없는 모델을 이미 쓰고 있어도 선택이
    /// 사라지지 않게 현재 값을 함께 넣는다.
    var modelOptions: [String] {
        let current = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !availableModels.contains(current) else { return availableModels }
        return [current] + availableModels
    }

    // MARK: - 동작

    func save() {
        store.setString(baseURL, forKey: Self.baseURLKey(provider))
        store.setString(model, forKey: Self.modelKey(provider))

        // 키 칸이 바뀌지 않았으면 키체인을 건드리지 않는다. 키체인 읽기가 거부돼
        // 칸이 빈 상태에서 저장을 누르면, 무조건 쓰기는 보관 중인 키를 삭제한다
        // (읽기는 ACL이 막지만 삭제는 통과한다). 모델 이름만 고쳐도 키가 날아간다.
        if apiKey != savedSnapshot.apiKey {
            // 키체인 실패를 삼키면 "저장했다"고 표시된 키가 다음 실행에 사라진다.
            guard keyStore.setKey(provider.requiresAPIKey ? apiKey : nil, for: provider.rawValue)
            else {
                statusMessage = "키체인에 API 키를 저장하지 못했습니다. 키체인 접근 권한을 확인하세요."
                return
            }
        }

        savedSnapshot = Snapshot(baseURL: baseURL, model: model, apiKey: apiKey)
        statusMessage = "저장했습니다."
    }

    func resetToDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
        statusMessage = nil
    }

    /// 제공자에서 모델 목록을 받아 온다. 실패하면 목록을 비워 직접 입력으로 되돌린다 —
    /// 낡은 목록을 남겨 두면 지금 쓸 수 없는 모델을 고르게 된다.
    func refreshModels() {
        guard !isLoadingModels else { return }

        // CLI 제공자의 모델은 별칭이라 조회할 곳이 없다. 목록을 바로 채운다.
        if let tool = provider.cliTool {
            availableModels = tool.models
            statusMessage = "모델 \(tool.models.count)개 (CLI 별칭)."
            return
        }

        isLoadingModels = true
        statusMessage = "모델 목록을 불러오는 중…"

        let fetchModels = self.fetchModels
        let settings = self.settings
        let apiKey = apiKeyForRequest
        Task {
            do {
                let models = try await fetchModels(settings, apiKey)
                availableModels = models
                statusMessage = models.isEmpty
                    ? "고를 수 있는 모델이 없습니다. 모델 이름을 직접 입력하세요."
                    : "모델 \(models.count)개를 불러왔습니다."
            } catch {
                availableModels = []
                statusMessage = AIChatError.describe(error)
            }
            isLoadingModels = false
        }
    }

    /// 실제로 한 번 호출해 본다. 키·모델·URL 중 무엇이 틀렸는지는 서버 응답에만 있다.
    func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        statusMessage = "연결 확인 중…"

        let probePrompt = "You are a connectivity probe. Reply with OK."
        let probeMessages = [AIChatMessage(role: .user, text: "ping")]
        let makeStream: () -> AsyncThrowingStream<AIChatChunk, Error>
        do {
            switch provider.transport {
            case .http(let format):
                let request = try AIRequestBuilder.makeRequest(
                    settings: settings,
                    apiKey: apiKeyForRequest,
                    systemPrompt: probePrompt,
                    messages: probeMessages
                )
                let client = self.client
                makeStream = { client.stream(request: request, format: format) }
            case .localCLI(let tool):
                let invocation = try AICLIClient.makeInvocation(
                    tool: tool,
                    executablePath: baseURL,
                    model: model,
                    systemPrompt: probePrompt,
                    messages: probeMessages
                )
                let cliClient = self.cliClient
                makeStream = { cliClient.stream(invocation) }
            }
        } catch {
            statusMessage = AIChatError.describe(error)
            isTesting = false
            return
        }

        Task {
            var received = false
            var failure: String?
            do {
                for try await _ in makeStream() {
                    received = true
                    break
                }
            } catch {
                failure = AIChatError.describe(error)
            }

            if let failure {
                statusMessage = failure
            } else if received {
                statusMessage = "연결 성공."
            } else {
                // 2xx를 받았지만 본문이 비었다. 모델 이름이 틀린 경우가 흔하다.
                statusMessage = "연결은 되었지만 응답 본문이 비어 있습니다. 모델 이름을 확인하세요."
            }
            isTesting = false
        }
    }

    // MARK: - 저장소

    private func loadFields(for provider: AIProvider) {
        baseURL = store.string(forKey: Self.baseURLKey(provider)) ?? provider.defaultBaseURL
        model = store.string(forKey: Self.modelKey(provider)) ?? provider.defaultModel
        // 키는 배경에서 읽는다. 제공자 전환은 메인 스레드에서 일어나므로 여기서
        // 동기 키체인 호출을 하면 승인 다이얼로그가 UI를 그대로 멈춘다.
        apiKey = ""
        isKeyLoaded = false
        savedSnapshot = Snapshot(baseURL: baseURL, model: model, apiKey: "")
        statusMessage = nil
        // 이전 제공자의 모델 목록을 남겨 두면 다른 제공자의 모델을 고르게 된다.
        availableModels = []
    }

    private static func baseURLKey(_ provider: AIProvider) -> String {
        "AI.baseURL.\(provider.rawValue)"
    }

    private static func modelKey(_ provider: AIProvider) -> String {
        "AI.model.\(provider.rawValue)"
    }
}
