import Foundation

/// 점으로 이어진 숫자 버전. 문자열 비교로는 `1.10.0`이 `1.9.0`보다 작다고 나온다.
///
/// 사전 릴리스 표기(`1.3.0-beta.1`)는 숫자 앞부분만 읽고 나머지는 버린다. 이 앱은
/// 사전 릴리스를 배포하지 않고, 순서 규칙까지 구현하면 쓰이지 않는 코드가 남는다.
struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let numbers: [Int]

    /// `v1.2.0` · `1.2` · `1.3.0-beta`를 받는다. 숫자가 하나도 없으면 nil.
    init?(_ raw: String) {
        let withoutPrefix = raw.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let head = withoutPrefix.prefix { $0.isNumber || $0 == "." }
        // 빈 조각을 버리지 않는다. 기본값은 `1..2`를 ["1","2"]로 접어 1.2로 읽어 버린다.
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        // `1..2`처럼 빈 조각이 섞이면 파싱을 포기한다. 조용히 `1.2`로 읽으면 비교가 틀어진다.
        guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
        self.numbers = numbers
    }

    var description: String { numbers.map(String.init).joined(separator: ".") }

    /// 자리 수가 다르면 짧은 쪽을 0으로 채워 비교한다 — `1.2`와 `1.2.0`은 같은 버전이다.
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0 ..< max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// 합성된 `==`는 `numbers` 배열을 그대로 비교해 `1.2`와 `1.2.0`을 다르다고 본다.
    /// `<`의 규칙과 어긋나면 같은 두 버전이 정렬에서만 다르게 취급된다.
    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// 내려받아 설치할 수 있는 릴리스 한 건.
struct AppRelease: Sendable, Equatable {
    let version: SemanticVersion
    let dmgURL: URL
    /// DMG의 sha256이 담긴 파일. 옵셔널이 아닌 이유는 아래 `parse`의 주석에 있다.
    let checksumURL: URL
    let pageURL: URL
}

extension AppRelease {
    /// 키를 손으로 적는다. `.convertFromSnakeCase`는 `html_url`을 `htmlUrl`로 바꿔
    /// `htmlURL`과 어긋나고, 그 실패는 컴파일이 아니라 런타임 nil로만 드러난다.
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// GitHub `releases/latest` 응답에서 만든다.
    ///
    /// DMG와 `.sha256`이 **둘 다** 있어야 릴리스로 인정한다. 이 앱은 공증을 받지 않아
    /// 내려받은 번들의 서명으로 출처를 증명할 수 없다. 체크섬이 유일한 검증 수단이므로
    /// 없으면 업데이트 후보로 두지 않는다 — 검증 없는 자동 설치는 중간자가 실행 파일을
    /// 갈아 끼울 통로가 된다.
    static func parse(latestReleaseJSON data: Data) -> AppRelease? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(payload.tagName),
              let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let checksum = payload.assets.first(where: { $0.name == "\(dmg.name).sha256" })
        else { return nil }

        return AppRelease(
            version: version,
            dmgURL: dmg.browserDownloadURL,
            checksumURL: checksum.browserDownloadURL,
            pageURL: payload.htmlURL
        )
    }
}
