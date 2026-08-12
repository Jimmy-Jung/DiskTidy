import SwiftUI

/// AI Agent 제공자 연결 설정. 값은 제공자별로 저장되고 API 키만 키체인으로 간다.
struct SettingsTabView: View {
    @EnvironmentObject private var settings: AISettingsViewModel

    /// 목록에 없는 모델(사내 게이트웨이·프리뷰 등)을 쓰려면 직접 입력으로 빠져나간다.
    @State private var entersModelManually = false

    /// `ContentView`와 같은 키를 본다. 값이 바뀌면 그쪽 `onChange`가 창 레벨을 바꾼다.
    @AppStorage(WindowPresenter.alwaysOnTopKey, store: AppDefaults.shared) private var isAlwaysOnTop = true

    /// 개발자용 문의 창구. `UpdateChecker`가 보는 저장소와 같은 곳이다.
    private static let gitHubIssueURL = URL(string: "https://github.com/Jimmy-Jung/DiskTidy/issues/new")!

    /// 비개발자용 문의 창구. 제목에 앱 버전을 미리 채워 "버전이 뭐예요?" 왕복을 줄인다.
    private static let contactMailURL: URL = {
        let subject = "DiskTidy 문의 (v\(AppInfo.displayVersion))"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "joony300@gmail.com"
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        // scheme·path·쿼리를 모두 코드로 채우므로 실패할 수 없다.
        return components.url!
    }()

    @State private var isConfirmingLocalCLI = false

    /// 로컬 CLI 제공자 옵트인.
    ///
    /// 기본으로 숨기는 이유는 기술이 아니라 자격이다. 앱은 토큰을 읽지도 위장하지도 않고
    /// 사용자가 터미널에서 직접 치는 것과 같은 명령을 실행할 뿐이지만, 결과적으로 내 구독으로
    /// 앱이 요청을 내보낸다. 그 판단을 사용자가 내리게 한다.
    @ViewBuilder
    private var localCLISection: some View {
        Section("로컬 CLI 제공자") {
            Toggle("이미 로그인된 로컬 CLI 사용", isOn: localCLIBinding)
            Text(
                """
                Claude Code · Codex CLI를 자식 프로세스로 실행해 답을 받습니다. 앱은 토큰을 \
                읽거나 헤더를 위장하지 않고, 인증은 CLI가 이미 갖고 있는 것을 그대로 씁니다. \
                요청은 당신의 구독으로 나갑니다 — 각 제공자 약관에서 허용되는지는 직접 \
                확인하세요.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if settings.provider.cliTool == .codex {
                Text(
                    """
                    Codex CLI는 답을 조각 단위로 보내지 않습니다. 완성된 뒤 한 번에 표시됩니다. \
                    모델 칸을 비우면 CLI 자기 설정(~/.codex/config.toml)의 모델을 씁니다.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .alert("로컬 CLI를 사용할까요?", isPresented: $isConfirmingLocalCLI) {
            Button("사용", role: .destructive) { settings.isLocalCLIEnabled = true }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                """
                이 앱이 당신의 로컬 CLI를 실행하고, 요청은 당신의 구독으로 나갑니다. \
                앱은 자격증명을 만지지 않습니다. 제공자 약관에서 허용되는지는 직접 확인하세요.
                """
            )
        }
    }

    /// 켤 때만 확인을 받는다. 끄는 것은 되돌리기 쉬운 방향이라 그냥 끈다.
    private var localCLIBinding: Binding<Bool> {
        Binding(
            get: { settings.isLocalCLIEnabled },
            set: { isOn in
                if isOn {
                    isConfirmingLocalCLI = true
                } else {
                    settings.isLocalCLIEnabled = false
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("AI Agent 제공자") {
                Picker("제공자", selection: $settings.provider) {
                    // 로컬 CLI 제공자는 켜지 않으면 목록에 없다.
                    ForEach(settings.selectableProviders) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                TextField(settings.provider.endpointFieldLabel, text: $settings.baseURL)
                endpointHint

                modelField

                if settings.provider.requiresAPIKey {
                    SecureField("API 키", text: $settings.apiKey)
                    Text("키는 macOS 키체인에 저장됩니다. 설정 파일에는 남지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            localCLISection

            Section {
                HStack {
                    Button("저장") { settings.save() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("연결 테스트") { settings.testConnection() }
                        .disabled(settings.isTesting || !settings.isConfigured)
                    Button("기본값으로") { settings.resetToDefaults() }
                    if settings.isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    if settings.hasUnsavedChanges {
                        Text("저장되지 않은 변경 있음")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let status = settings.statusMessage {
                    Text(status).font(.callout).textSelection(.enabled)
                }
            }

            Section("창") {
                Toggle("항상 위에 표시", isOn: $isAlwaysOnTop)
                Text("Dock 아이콘이 없는 앱이라 다른 앱을 클릭하면 창이 가려집니다. "
                    + "켜 두면 정리 작업 중에도 창이 계속 보입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("보내지는 정보") {
                Text("""
                챗봇에 질문하면 그 순간 보고 있는 탭의 항목 이름·경로·용량·선택 상태가 \
                선택한 제공자의 서버로 전송됩니다. 파일 내용은 보내지 않습니다. \
                기기 밖으로 내보내고 싶지 않다면 OpenAI 호환(직접 입력)에 \
                로컬 서버 주소를 넣으세요.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("챗봇은 앱을 조작할 수 없습니다. 삭제·종료는 항상 사용자가 직접 버튼을 눌러야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("개발자에게 문의") {
                Link("GitHub 이슈 등록", destination: Self.gitHubIssueURL)
                Text("버그 신고와 기능 제안은 이슈로 남겨 주세요. 재현 방법을 함께 적으면 빨리 고쳐집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("메일 보내기", destination: Self.contactMailURL)
                Text("GitHub 계정이 없다면 메일로 보내 주세요. 제목에 앱 버전이 미리 채워집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 키체인 읽기는 앱 시작이 아니라 이 화면이 보인 뒤에 한다.
        .task {
            await settings.loadKeyIfNeeded()
            // 키가 채워진 뒤에야 목록을 물어볼 수 있다.
            if settings.availableModels.isEmpty, settings.canListModels {
                settings.refreshModels()
            }
        }
        .screenContext("설정") { [settings] in
            ScreenContextBuilder.settings(viewModel: settings)
        }
    }

    /// 전송 방식에 따라 첫 필드의 뜻이 달라진다. CLI 제공자는 약관 경계도 함께 밝힌다.
    @ViewBuilder
    private var endpointHint: some View {
        switch settings.provider.transport {
        case .http:
            Text("버전 경로(/v1/messages, /v1/chat/completions)는 자동으로 붙습니다. "
                + "평문 http는 루프백(localhost · 127.0.0.1 · ::1)에만 허용합니다 — "
                + "원격에 평문으로 보내면 API 키가 그대로 노출됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .localCLI(let tool):
            VStack(alignment: .leading, spacing: 4) {
                Text("개발 빌드 전용 · 본인 테스트용")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text("""
                이미 로그인된 \(tool.label)를 그대로 실행합니다. 앱은 자격증명을 읽지도 \
                저장하지도 않습니다 — 터미널에서 `\(tool.executableName) -p`를 치는 것과 같은 \
                경로입니다. 먼저 터미널에서 `\(tool.executableName)`을 실행해 로그인해 두세요.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                배포 빌드에서는 이 제공자를 고를 수 없습니다. 서드파티 앱이 사용자 구독으로 \
                요청을 대행하는 것은 제공자 약관이 금지합니다.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.isConfigured {
                    Text("실행 파일을 찾지 못했습니다. `which \(tool.executableName)` 결과를 넣으세요.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// 목록을 받아 왔으면 드롭다운, 없거나 직접 입력을 켰으면 텍스트 필드.
    @ViewBuilder
    private var modelField: some View {
        if settings.availableModels.isEmpty || entersModelManually {
            TextField("모델", text: $settings.model)
        } else {
            Picker("모델", selection: $settings.model) {
                ForEach(settings.modelOptions, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }

        HStack {
            Button("모델 목록 불러오기") { settings.refreshModels() }
                .disabled(settings.isLoadingModels || !settings.canListModels)
            if settings.isLoadingModels { ProgressView().controlSize(.small) }
            Spacer()
            Toggle("직접 입력", isOn: $entersModelManually)
                .toggleStyle(.checkbox)
        }

        if !settings.canListModels {
            Text("목록을 불러오려면 API 루트 URL과 (필요한 경우) API 키를 먼저 채우세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
