import SwiftUI

/// 챗봇 답변의 블록 하나. 줄 단위 구조만 담고, 인라인 서식은 `MarkdownParser.attributed`가 맡는다.
enum MarkdownBlock: Equatable {
    /// 문단. 모델이 의도적으로 넣은 줄바꿈을 보존하려고 연속한 줄을 `\n`으로 이어 둔다.
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case code(String)
}

/// 챗봇 답변에 필요한 만큼의 마크다운만 해석한다.
///
/// 전체 마크다운 파서를 넣지 않는다. 모델이 실제로 쓰는 것은 굵게·기울임·인라인 코드,
/// 글머리표, 번호 목록, 제목, 코드 블록뿐이다. 인라인 서식은 Foundation에 맡기고
/// 여기서는 줄 단위 블록 구조만 나눈다.
enum MarkdownParser {
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 코드 블록은 스트리밍 중 닫히지 않은 채로 도착한다. 열려 있으면 그대로 담는다.
            if trimmed.hasPrefix("```") {
                if let open = codeLines {
                    blocks.append(.code(open.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let bullet = bullet(in: trimmed) {
                flushParagraph()
                blocks.append(bullet)
                continue
            }
            if let numbered = numbered(in: trimmed) {
                flushParagraph()
                blocks.append(numbered)
                continue
            }
            paragraph.append(trimmed)
        }

        flushParagraph()
        if let open = codeLines { blocks.append(.code(open.joined(separator: "\n"))) }
        return blocks
    }

    /// 인라인 서식(굵게·기울임·인라인 코드·링크)만 해석한다.
    ///
    /// 스트리밍 중에는 `**굵게`처럼 닫히지 않은 문법이 도착하므로 부분 해석을 허용하고,
    /// 그래도 실패하면 원문을 그대로 보여 준다 — 서식 때문에 내용을 잃으면 안 된다.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - 줄 판정

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        // `#태그`는 제목이 아니다. 마크다운은 `#` 뒤에 공백을 요구한다.
        guard rest.first == " " else { return nil }
        return .heading(
            level: hashes.count,
            text: String(rest).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func bullet(in line: String) -> MarkdownBlock? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return .bullet(String(line.dropFirst(marker.count)))
        }
        return nil
    }

    private static func numbered(in line: String) -> MarkdownBlock? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .numbered(marker: "\(digits).", text: String(rest.dropFirst(2)))
    }
}

/// 마크다운 문자열을 그린다. 챗봇 답변 전용이며, 사용자가 입력한 텍스트에는 쓰지 않는다
/// (사용자가 적은 `*`나 `_`가 서식으로 먹히면 원문이 바뀐 것처럼 보인다).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 블록은 순서로만 식별한다. 내용이 같은 줄이 겹쳐도 흔들리지 않는다.
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownParser.attributed(text))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            Text(MarkdownParser.attributed(text))
                .font(level <= 2 ? .headline : .subheadline)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case .bullet(let text):
            listRow(marker: "•", text: text)

        case .numbered(let marker, let text):
            listRow(marker: marker, text: text)

        case .code(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(MarkdownParser.attributed(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
