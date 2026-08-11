import AppKit
import MarkdownView
import SwiftUI

/// 오른쪽 챗봇 패널. 현재 탭이 등록한 화면 스냅샷을 근거로 대화한다.
struct ChatPanelView: View {
    /// 폭은 사용자가 끌어 바꾼다. 340pt로는 표 세 열과 80자 코드가 들어가지 않는다.
    static let defaultWidth: Double = 440
    static let minimumWidth: Double = 320
    static let maximumWidth: Double = 720

    private static let scrollSpace = "ChatScroll"
    private static let bottomAnchorID = "ChatBottomAnchor"

    let width: Double

    @EnvironmentObject private var navState: AppNavigationState
    @EnvironmentObject private var contextStore: ChatContextStore
    @EnvironmentObject private var settings: AISettingsViewModel
    @EnvironmentObject private var chat: ChatViewModel

    @State private var tailFollow = TailFollowTracker()
    @FocusState private var isInputFocused: Bool
    @StateObject private var returnKey = ReturnKeySender()

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
        .frame(width: width)
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
            // 진행 표시는 여기가 아니라 답변 자리에 둔다. 머리말에 두면 어느 답변을
            // 기다리는 중인지 눈이 이어지지 않는다.
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
            messageList.chatMarkdownStyle()
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

    /// 스트리밍 중에는 답변 본문이 `@Published`를 거치지 않는다. 그래서 "새 조각이 왔다"를
    /// 텍스트 변화로 알 수 없고, 대신 콘텐츠 높이가 자라는 것으로 잡는다.
    ///
    /// 높이 변화와 위치 변화를 나눠 보는 것이 핵심이다. 예전에는 `DragGesture`로
    /// 사용자 스크롤을 감지했는데, macOS의 휠·트랙패드 스크롤은 드래그 제스처를 만들지
    /// 않아 답변이 흐르는 동안 위를 읽으면 매번 바닥으로 끌려 내려갔다. 반대로 한 번
    /// 따라가기가 꺼지면 바닥으로 돌아와도 다시 붙지 않았다.
    private var messageList: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.messages) { message in
                            MessageRow(
                                message: message,
                                streamingSource: streamingSource(for: message),
                                isAwaitingFirstChunk: chat.streamingReplyID == message.id
                                    && chat.isAwaitingFirstChunk,
                                canRegenerate: chat.isLastAnswer(message) && !chat.isStreaming,
                                onRegenerate: regenerate,
                                onEdit: { chat.moveMessageToInput(id: message.id) }
                            )
                            .id(message.id)
                        }
                        // 마지막 말풍선이 아니라 이 점을 기준으로 끝을 잡는다.
                        // 말풍선이 뷰포트보다 높아도 항상 진짜 바닥으로 간다.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(metricsReader)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ScrollMetricsKey.self) { metrics in
                    let scrollsToBottom = tailFollow.update(
                        contentHeight: metrics.contentHeight,
                        contentBottom: metrics.contentBottom,
                        viewportHeight: viewport.size.height
                    )
                    if scrollsToBottom { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 콘텐츠 사각형을 스크롤 뷰포트 좌표로 읽어 올린다.
    private var metricsReader: some View {
        GeometryReader { content in
            let frame = content.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(
                key: ScrollMetricsKey.self,
                value: ScrollMetrics(contentHeight: frame.height, contentBottom: frame.maxY)
            )
        }
    }

    /// 지금 흘러오는 답변의 말풍선에만 스트리밍 원본을 넘긴다.
    private func streamingSource(for message: AIChatMessage) -> StreamingMarkdownSource? {
        chat.streamingReplyID == message.id ? chat.streamingSource : nil
    }

    // MARK: - 입력

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            inputField
            actionButton
        }
        .padding(10)
        // 패널을 열면 바로 칠 수 있게 한다. 커서를 어디에 놓아야 하는지 찾게 만들지 않는다.
        .onAppear {
            isInputFocused = true
            returnKey.isEnabled = true
            returnKey.start()
        }
        .onDisappear { returnKey.stop() }
        // 포커스가 입력창에 없는 동안에는 Return을 가로채지 않는다.
        .onChange(of: isInputFocused) { returnKey.isEnabled = isInputFocused }
        .onChange(of: returnKey.pressCount) { send() }
    }

    /// 다섯 줄까지 자란다. 그보다 길면 스크롤한다 — 계속 자라게 두면 입력창이 대화를 덮는다.
    ///
    /// 여기에 `onKeyPress`를 붙이지 않는다. 그 모디파이어는 붙은 뷰를 키 입력 대상으로
    /// 만들어서, TextField 위에 얹으면 텍스트 편집기가 키 포커스를 받지 못하고 입력이
    /// 아예 안 된다(실제로 그렇게 막혔다). Return으로 보내려면 NSTextView를 감싸야 한다.
    /// 지금은 ⌘Return을 쓴다.
    private var inputField: some View {
        TextField("이 화면에 대해 물어보세요", text: $chat.input, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isInputFocused)
            .disabled(!settings.isConfigured)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.secondary.opacity(0.25))
                    // 테두리는 장식이다. 히트테스트를 켜 두면 가운데 클릭을 가로채
                    // 필드가 포커스를 받지 못한다.
                    .allowsHitTesting(false)
            }
            // `.plain` 스타일은 글자가 놓인 줄만 클릭을 받는다. 여기서 패딩을 준 뒤
            // 상자 전체를 눌러도 포커스가 가게 만들지 않으면, 둥근 상자의 대부분이
            // 죽은 영역이 되어 눌러도 커서가 생기지 않는다. `.roundedBorder`는 자기
            // 테두리 안쪽 전체를 처리해 주므로 이 문제가 없었다.
            .contentShape(Rectangle())
            .onTapGesture { isInputFocused = true }
    }

    @ViewBuilder
    private var actionButton: some View {
        if chat.isStreaming {
            ComposerButton(icon: "stop.circle.fill", help: "중단", action: chat.cancel)
        } else {
            ComposerButton(icon: "play.circle.fill", help: "보내기", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chat.canSend || !settings.isConfigured)
        }
    }

    private func send() {
        guard settings.isConfigured, chat.canSend else { return }
        // 새 질문을 보내면 다시 바닥을 따라간다.
        tailFollow.followTail()
        chat.send(
            settings: settings.settings,
            apiKey: settings.apiKeyForRequest,
            context: contextStore.current()
        )
    }

    private func regenerate() {
        guard settings.isConfigured else { return }
        tailFollow.followTail()
        chat.regenerateLastAnswer(
            settings: settings.settings,
            apiKey: settings.apiKeyForRequest,
            context: contextStore.current()
        )
    }
}

/// Return을 보내기로, Shift+Return을 줄바꿈으로 쓰기 위한 키 이벤트 감시자.
///
/// 왜 이런 방법인가:
/// - 세로로 늘어나는 `TextField`는 Return을 줄바꿈으로 소비하므로 `onSubmit`이 오지 않는다.
/// - `.onKeyPress`를 그 `TextField`에 붙이면 붙은 뷰가 키 입력 대상이 되어 **타이핑 자체가
///   막힌다**(실측). 그래서 필드를 건드리지 않고 이벤트를 앱 수준에서 한 번 훔쳐본다.
///
/// 누른 사실만 발행하고 실제 전송은 뷰가 한다. 클로저를 여기 담아 두면 그 안에 갇힌
/// 옛 뷰 값으로 상태를 고치게 되어, 화면과 어긋난 상태로 보내게 된다.
@MainActor
final class ReturnKeySender: ObservableObject {
    /// Return 키 코드. 숫자패드 Enter는 따로 온다.
    nonisolated private static let returnKeyCodes: Set<UInt16> = [36, 76]

    @Published private(set) var pressCount = 0

    /// 입력창이 포커스를 가진 동안에만 켠다. 꺼진 채로 두지 않으면 설정 탭 입력란의
    /// Return까지 먹는다.
    var isEnabled = false

    private var monitor: Any?

    /// 이 Return 이벤트를 어떻게 처리할지.
    enum Action: Equatable {
        case send
        /// 줄바꿈을 직접 넣어야 한다. macOS의 세로 `TextField`는 **맨 Return**으로만
        /// 줄바꿈하고 Shift+Return에는 아무 반응이 없다. 맨 Return을 보내기로 가져갔으니
        /// 줄바꿈 수단이 없어져, 이쪽에서 캐럿 자리에 개행을 넣어 준다.
        case insertNewline
        /// 우리 것이 아니다. 그대로 흘려보낸다.
        case pass
    }

    /// 뷰·AppKit 이벤트 없이 검증할 수 있게 값만 받는다.
    nonisolated static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isComposing: Bool,
        isEnabled: Bool
    ) -> Action {
        guard isEnabled, returnKeyCodes.contains(keyCode) else { return .pass }
        // 한글 조합 중의 Return은 음절을 확정하는 입력이다. 가로채면 마지막 글자가 빠진 채로
        // 전송되거나 확정이 사라진다. 확정된 다음 Return이 보내기가 된다.
        guard !isComposing else { return .pass }
        // ⌘Return은 보내기 버튼의 단축키가 이미 처리한다. ⌥·⌃ 조합은 우리 것이 아니다.
        guard modifiers.intersection([.command, .option, .control]).isEmpty else { return .pass }

        return modifiers.contains(.shift) ? .insertNewline : .send
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
            switch Self.action(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isComposing: editor?.hasMarkedText() ?? false,
                isEnabled: self.isEnabled
            ) {
            case .send:
                self.pressCount += 1
                return nil
            case .insertNewline:
                // 필드 에디터에 직접 넣는다. 바인딩 문자열 끝에 붙이면 캐럿이 중간에
                // 있을 때 엉뚱한 자리에 줄이 생긴다.
                guard let editor else { return event }
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return nil
            case .pass:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 입력줄 오른쪽의 아이콘 버튼. 보내기와 중단이 같은 자리를 쓴다.
private struct ComposerButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(help)
        .padding(.bottom, 2)
    }
}

/// 스크롤 판단에 필요한 최소 수치. 뷰포트 좌표 기준이다.
struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    /// 콘텐츠 끝의 y. 뷰포트 높이보다 크면 바닥이 화면 아래에 남아 있다.
    var contentBottom: CGFloat
}

private struct ScrollMetricsKey: PreferenceKey {
    static let defaultValue = ScrollMetrics(contentHeight: 0, contentBottom: 0)

    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        value = nextValue()
    }
}

/// 답변이 흘러오는 동안 바닥을 따라갈지 판단한다.
///
/// 뷰에서 떼어낸 이유는 여기가 틀리면 증상이 고약하기 때문이다. 예전 구현은
/// `DragGesture`로 사용자 스크롤을 감지했는데, macOS의 휠·트랙패드 스크롤은 드래그
/// 제스처를 만들지 않아 답변이 흐르는 동안 위를 읽으면 매번 바닥으로 끌려 내려갔다.
/// 반대로 한 번 따라가기가 꺼지면 바닥으로 돌아와도 다시 붙지 않았다.
///
/// 판단의 핵심은 **높이 변화와 위치 변화를 나눠 보는 것**이다. 답변이 자라면 높이가
/// 늘고 바닥이 뷰포트 아래로 밀려나는데, 그 밀림을 사용자 스크롤로 오해하면 첫 조각에
/// 곧바로 따라가기가 꺼진다.
struct TailFollowTracker: Equatable {
    /// 바닥에 붙어 있다고 볼 여유. 스크롤 위치는 딱 떨어지지 않는다.
    static let threshold: CGFloat = 24

    private(set) var followsTail = true
    private var contentHeight: CGFloat = 0
    private var distanceFromBottom: CGFloat = 0

    /// 새 수치를 반영하고, 바닥으로 스크롤해야 하는지 알린다.
    mutating func update(
        contentHeight: CGFloat, contentBottom: CGFloat, viewportHeight: CGFloat
    ) -> Bool {
        let gap = contentBottom - viewportHeight
        defer { distanceFromBottom = gap }

        // 높이가 자랐다 = 답변이 흘러오는 중이거나 말풍선이 늘었다. 붙어 있었으면
        // 계속 따라가고, 따라가기 여부는 다시 판단하지 않는다.
        if contentHeight != self.contentHeight {
            self.contentHeight = contentHeight
            return followsTail
        }

        // 높이는 그대로인데 끝까지의 거리가 바뀌었다 = 사용자가 스크롤했다.
        // 바닥으로 돌아오면 다시 붙는다.
        if gap != distanceFromBottom {
            followsTail = gap < Self.threshold
        }
        return false
    }

    /// 새 질문을 보냈다. 다시 바닥을 따라간다.
    mutating func followTail() {
        followsTail = true
    }
}

/// 대화 한 줄.
///
/// 답변은 배경 없이 패널 폭을 다 쓰고, 사용자 질문만 오른쪽 정렬 말풍선으로 둔다.
/// 둘 다 같은 회색 상자에 넣으면 표·코드 블록이 상자 안에 갇혀 좁아지고, 어느 쪽이
/// 내 말인지도 색 차이 하나로만 구분해야 한다.
private struct MessageRow: View {
    let message: AIChatMessage

    /// 이 줄이 지금 흘러오는 답변일 때만 값이 있다.
    let streamingSource: StreamingMarkdownSource?

    /// 요청은 나갔는데 첫 조각이 아직 안 왔다. 답변 자리에 진행 표시를 둔다.
    let isAwaitingFirstChunk: Bool

    /// 마지막 답변에만 재생성을 붙인다. 중간 답변을 다시 만들면 뒤 대화와 어긋난다.
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            switch message.role {
            case .user: userRow
            case .assistant: assistantRow
            }
        }
        // 행 전체를 hover 대상으로 만든다. 이게 없으면 글자 사이 빈 곳이나 액션 줄의
        // 투명한 여백에서 hover가 끊긴다.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    // MARK: - 사용자

    private var userRow: some View {
        HStack {
            Spacer(minLength: 32)
            VStack(alignment: .trailing, spacing: 2) {
                // 사용자가 적은 `*`나 `_`를 서식으로 먹으면 원문이 바뀐 것처럼 보인다.
                Text(message.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.accentColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                actions(alignment: .trailing) {
                    ActionButton(icon: "pencil", help: "고쳐서 다시 보내기", action: onEdit)
                    CopyMessageButton(text: message.text)
                }
            }
        }
    }

    // MARK: - 답변

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // 스트리밍 중에는 이 표시가 맥동한다. 본문 끝 커서 대신 여기를 쓴다 —
                // 마크다운 원문에 커서 문자를 끼우면 코드 블록·표 안으로 섞여 들어간다.
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(isStreaming ? Color.accentColor : Color.secondary)
                    .opacity(isStreaming ? 0.4 : 1)
                    .animation(
                        isStreaming
                            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                            : .default,
                        value: isStreaming
                    )
                Text("AI")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // 첫 조각을 기다리는 동안 빈 자리를 두면 멈춘 것처럼 보인다. CLI 제공자는
            // 기동과 사고 블록에 몇 초를 쓰므로 이 구간이 짧지 않다.
            if isAwaitingFirstChunk {
                waitingIndicator
            } else {
                answerBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actions(alignment: .leading) {
                CopyMessageButton(text: message.text)
                if canRegenerate {
                    ActionButton(
                        icon: "arrow.clockwise", help: "다시 생성", action: onRegenerate
                    )
                }
            }
        }
    }

    /// 흘러오는 중과 완결된 뒤 모두 `MarkdownText`로 그린다. 스트리밍용으로 권장되는
    /// `MarkdownView`(블록을 SwiftUI 뷰로 쌓는 방식)로 그리면 완결 시점에 렌더러가
    /// 바뀌면서 레이아웃이 한 번 튀고, 문단을 넘는 텍스트 선택도 못 한다.
    @ViewBuilder
    private var answerBody: some View {
        if let streamingSource {
            StreamingMarkdownReader(streamingSource) { MarkdownText($0) }
        } else {
            MarkdownText(message.text)
        }
    }

    private var waitingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("답변을 준비하는 중…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isStreaming: Bool { streamingSource != nil }

    /// 흘러오는 중에는 액션을 감춘다. 아직 본문이 `message.text`에 없어서 복사해도 빈 값이다.
    private var isVisible: Bool { isHovering && !isStreaming }

    // MARK: - 행 액션

    /// 마우스를 올릴 때만 보인다. 자리는 항상 잡아 둔다 — 나타날 때마다 줄이 밀리면
    /// 읽던 위치가 흔들리고, 스트리밍 중에는 바닥 추적까지 덜컹거린다.
    private func actions<Content: View>(
        alignment: HorizontalAlignment, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            if alignment == .trailing { Spacer() }
            content()
            if alignment == .leading { Spacer() }
        }
        .opacity(isVisible ? 1 : 0)
        // 투명해도 SwiftUI는 계속 눌러 주므로 눌리지 않게 막는다. 다만 `allowsHitTesting`은
        // 쓰지 않는다 — 히트테스트를 끄면 이 줄이 hover 감지에서도 빠져, 커서를 글자에서
        // 버튼으로 옮기는 순간 hover가 false가 되고 버튼이 사라진다(자기 참조 루프).
        // `disabled`는 히트테스트를 유지하면서 클릭만 막는다.
        .disabled(!isVisible)
        .frame(height: 22)
    }
}

/// 행 액션 버튼. 아이콘만 두고 설명은 툴팁에 맡긴다.
private struct ActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// 메시지 전체를 클립보드로 옮긴다. 원문 마크다운을 그대로 넘긴다 — 다른 곳에 붙일 때
/// 서식이 살아 있는 편이 쓸모 있다.
private struct CopyMessageButton: View {
    let text: String

    @State private var hasCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hasCopied = true
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("복사")
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            hasCopied = false
        }
    }
}
