import SwiftUI

/// 오른쪽 챗봇 패널. 현재 탭이 등록한 화면 스냅샷을 근거로 대화한다.
struct ChatPanelView: View {
    static let width: CGFloat = 340

    @EnvironmentObject private var navState: AppNavigationState
    @EnvironmentObject private var contextStore: ChatContextStore
    @EnvironmentObject private var settings: AISettingsViewModel
    @EnvironmentObject private var chat: ChatViewModel

    /// 바닥을 따라갈지. 사용자가 위로 스크롤하면 끈다 — 조각마다 바닥으로 끌어내리면
    /// 답변이 흐르는 동안 위를 읽거나 텍스트를 선택할 수 없다.
    @State private var followsTail = true

    private static let sampleQuestions = [
        "이 화면을 요약해줘",
        "지금 선택한 항목을 지우면 얼마나 확보돼?",
        "안전하게 지워도 되는 항목은 어떤 거야?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            conversation
            if let message = chat.errorMessage {
                ErrorBanner(message: message) { chat.errorMessage = nil }
                    .padding(.horizontal, 10)
            }
            Divider()
            composer
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .controlBackgroundColor))
        // 키체인 읽기는 앱 시작이 아니라 패널이 보인 뒤에 한다.
        .task { await settings.loadKeyIfNeeded() }
    }

    // MARK: - 머리말

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 도우미").font(.headline)
                Text("현재 화면: \(contextStore.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if chat.isStreaming { ProgressView().controlSize(.small) }
            Button("새 대화") { chat.clear() }
                .disabled(chat.messages.isEmpty && !chat.isStreaming)
        }
        .padding(10)
    }

    // MARK: - 본문

    /// 설정이 풀렸다고 대화를 치우지 않는다. 설정 탭에서 모델명을 고치는 중에
    /// `isConfigured`가 잠깐 false가 되는데, 그때 대화가 사라진 것처럼 보인다.
    @ViewBuilder
    private var conversation: some View {
        if !chat.messages.isEmpty {
            messageList
        } else if settings.isConfigured {
            emptyState
        } else {
            setupNotice
        }
    }

    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 제공자가 연결되지 않았습니다.")
            Text("설정 탭에서 제공자·모델·API 키를 입력하면 지금 보고 있는 화면에 대해 물어볼 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("설정 열기") { navState.selectedTab = AppNavigationState.settingsTab }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이 화면의 정보로 답합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Self.sampleQuestions, id: \.self) { question in
                Button(question) { chat.input = question }
                    .buttonStyle(.link)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 사용자가 손으로 스크롤을 올리면 따라가기를 멈춘다.
            .simultaneousGesture(DragGesture().onChanged { _ in followsTail = false })
            // 답변이 길어지면 사용자가 따라 스크롤해야 한다. 새 조각마다 바닥으로 붙인다.
            .onChange(of: chat.messages.last?.id) { _ in scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.text) { _ in scrollToBottom(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsTail, let last = chat.messages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // MARK: - 입력

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("이 화면에 대해 물어보세요", text: $chat.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!settings.isConfigured)
                .onSubmit(send)

            HStack(alignment: .bottom) {
                // 무엇이 밖으로 나가는지 입력창 옆에 항상 붙여 둔다.
                Text("보내면 이 화면의 항목 이름·경로·용량이 \(settings.provider.label)로 전송됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if chat.isStreaming {
                    Button("중단") { chat.cancel() }
                } else {
                    Button("보내기", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!chat.canSend || !settings.isConfigured)
                }
            }
        }
        .padding(10)
    }

    private func send() {
        guard settings.isConfigured, chat.canSend else { return }
        // 새 질문을 보내면 다시 바닥을 따라간다.
        followsTail = true
        chat.send(
            settings: settings.settings,
            apiKey: settings.apiKeyForRequest,
            context: contextStore.current()
        )
    }
}

private struct MessageBubble: View {
    let message: AIChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.role == .user ? "나" : "AI")
                .font(.caption2)
                .foregroundStyle(.secondary)
            content
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 모델 답변만 마크다운으로 그린다. 사용자가 입력한 텍스트에 서식을 적용하면
    /// 직접 적은 `*`나 `_`가 사라져 원문이 바뀐 것처럼 보인다.
    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user: Text(message.text)
        case .assistant: MarkdownText(text: message.text)
        }
    }

    private var background: Color {
        message.role == .user
            ? Color.accentColor.opacity(0.15)
            : Color.secondary.opacity(0.12)
    }
}
