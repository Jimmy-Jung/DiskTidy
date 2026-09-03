import CryptoKit
import Foundation
import Testing

@testable import DiskTidy

// MARK: - SemanticVersion

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test("v 접두사와 자리 수 차이를 흡수한다")
    func parsesCommonForms() throws {
        #expect(SemanticVersion("v1.2.0")?.description == "1.2.0")
        #expect(SemanticVersion("1.2")?.description == "1.2")
        // 사전 릴리스 꼬리는 버린다.
        #expect(SemanticVersion("1.3.0-beta.1")?.description == "1.3.0")
    }

    @Test("숫자가 없거나 조각이 비면 nil")
    func rejectsGarbage() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("v") == nil)
        // `1..2`를 조용히 1.2로 읽으면 비교가 틀어진다.
        #expect(SemanticVersion("1..2") == nil)
    }

    @Test("문자열 비교로는 틀리는 자리 수를 숫자로 비교한다")
    func comparesNumerically() throws {
        let nine = try #require(SemanticVersion("1.9.0"))
        let ten = try #require(SemanticVersion("1.10.0"))
        #expect(nine < ten)
        #expect(!(ten < nine))
    }

    @Test("짧은 쪽을 0으로 채워 같은 버전으로 본다")
    func padsMissingComponents() throws {
        let short = try #require(SemanticVersion("1.2"))
        let long = try #require(SemanticVersion("1.2.0"))
        #expect(short == long)
        #expect(!(short < long))
        #expect(!(long < short))
    }
}

// MARK: - 릴리스 파싱

@Suite("AppRelease 파싱")
struct AppReleaseParsingTests {
    private func json(assets: String, tag: String = "v9.9.9") -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "html_url": "https://example.invalid/releases/\(tag)",
          "assets": [\(assets)]
        }
        """.utf8)
    }

    private let dmg = """
    {"name": "DiskTidy-9.9.9.dmg",
     "browser_download_url": "https://example.invalid/DiskTidy-9.9.9.dmg"}
    """
    private let checksum = """
    {"name": "DiskTidy-9.9.9.dmg.sha256",
     "browser_download_url": "https://example.invalid/DiskTidy-9.9.9.dmg.sha256"}
    """

    @Test("DMG와 체크섬이 둘 다 있으면 릴리스가 된다")
    func parsesFullRelease() throws {
        let release = try #require(
            AppRelease.parse(latestReleaseJSON: json(assets: "\(dmg),\(checksum)"))
        )
        #expect(release.version.description == "9.9.9")
        #expect(release.dmgURL.lastPathComponent == "DiskTidy-9.9.9.dmg")
        #expect(release.checksumURL.lastPathComponent == "DiskTidy-9.9.9.dmg.sha256")
    }

    @Test("체크섬 파일이 없으면 후보로 삼지 않는다")
    func rejectsReleaseWithoutChecksum() {
        // 검증 없는 자동 설치는 만들지 않는다.
        #expect(AppRelease.parse(latestReleaseJSON: json(assets: dmg)) == nil)
    }

    @Test("DMG가 없으면 후보로 삼지 않는다")
    func rejectsReleaseWithoutDMG() {
        #expect(AppRelease.parse(latestReleaseJSON: json(assets: checksum)) == nil)
    }

    @Test("태그를 숫자로 읽을 수 없으면 nil")
    func rejectsUnparsableTag() {
        let body = json(assets: "\(dmg),\(checksum)", tag: "nightly")
        #expect(AppRelease.parse(latestReleaseJSON: body) == nil)
    }

    @Test("깨진 본문은 nil")
    func rejectsBrokenBody() {
        #expect(AppRelease.parse(latestReleaseJSON: Data("not json".utf8)) == nil)
    }
}

// MARK: - 요청 한도

@Suite("GitHub 요청 한도")
struct RateLimitTests {
    private func response(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: UpdateChecker.latestReleaseURL,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: headers
        ))
    }

    @Test("남은 횟수가 0인 403은 리셋 시각을 담은 한도 초과로 읽는다")
    func readsResetTime() throws {
        let http = try response(status: 403, headers: [
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1788429685",
        ])
        #expect(
            UpdateChecker.rateLimitError(http)
                == .rateLimited(until: Date(timeIntervalSince1970: 1_788_429_685))
        )
    }

    @Test("리셋 헤더가 없어도 한도 초과로 알린다")
    func toleratesMissingReset() throws {
        let http = try response(status: 429, headers: ["x-ratelimit-remaining": "0"])
        #expect(UpdateChecker.rateLimitError(http) == .rateLimited(until: nil))
    }

    @Test("남은 횟수가 있는 403은 한도가 아니라 권한 문제다")
    func ignoresOtherForbidden() throws {
        let http = try response(status: 403, headers: ["x-ratelimit-remaining": "12"])
        #expect(UpdateChecker.rateLimitError(http) == nil)
    }

    @Test("성공 응답은 한도로 읽지 않는다")
    func ignoresSuccess() throws {
        let http = try response(status: 200, headers: ["x-ratelimit-remaining": "0"])
        #expect(UpdateChecker.rateLimitError(http) == nil)
    }

    @Test("안내에 리셋 시각이 들어간다")
    func messageNamesResetTime() throws {
        let reset = Date(timeIntervalSince1970: 1_788_429_685)
        let message = try #require(UpdateError.rateLimited(until: reset).errorDescription)
        #expect(message.contains(reset.formatted(date: .omitted, time: .shortened)))
    }
}

// MARK: - 체크섬

@Suite("업데이트 체크섬")
struct UpdateChecksumTests {
    @Test("shasum 출력에서 해시만 뽑는다")
    func readsChecksumLine() {
        let hash = String(repeating: "a", count: 64)
        #expect(UpdateInstaller.expectedChecksum(from: "\(hash)  DiskTidy-9.9.9.dmg\n") == hash)
    }

    @Test("대문자 해시도 소문자로 맞춘다")
    func normalizesCase() {
        let upper = String(repeating: "AB", count: 32)
        #expect(UpdateInstaller.expectedChecksum(from: "\(upper)  x.dmg") == upper.lowercased())
    }

    @Test("64자 hex가 없으면 nil")
    func rejectsNonChecksum() {
        #expect(UpdateInstaller.expectedChecksum(from: "no hash here") == nil)
        #expect(UpdateInstaller.expectedChecksum(from: String(repeating: "a", count: 63)) == nil)
        #expect(UpdateInstaller.expectedChecksum(from: "") == nil)
    }

    @Test("계산한 해시가 CryptoKit 결과와 같다")
    func hashesData() {
        let data = Data("DiskTidy".utf8)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(UpdateInstaller.sha256Hex(of: data) == expected)
    }
}

// MARK: - 번들 교체

@Suite("번들 교체")
struct BundleReplacementTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    /// `.app` 흉내만 낸 디렉터리. 교체 함수는 번들 내용을 보지 않는다.
    private func makeBundle(_ name: String, marker: String) throws -> URL {
        let bundle = try temp.makeDirectory(name)
        try Data(marker.utf8).write(to: bundle.appendingPathComponent("marker.txt"))
        return bundle
    }

    @Test("새 번들이 자리를 차지하고 백업은 남지 않는다")
    func replacesBundle() throws {
        let target = try makeBundle("Target.app", marker: "old")
        let source = try makeBundle("Source.app", marker: "new")

        try UpdateInstaller.replaceBundle(at: target, withCopyOf: source)

        let marker = try Data(contentsOf: target.appendingPathComponent("marker.txt"))
        #expect(String(decoding: marker, as: UTF8.self) == "new")
        // 백업 잔여물이 남으면 업데이트마다 쌓인다.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
            .filter { $0.contains(".backup-") }
        #expect(leftovers.isEmpty)
    }

    @Test("복사가 실패하면 이전 번들을 되돌린다")
    func rollsBackWhenCopyFails() throws {
        let target = try makeBundle("Target.app", marker: "old")
        let missing = temp.url.appendingPathComponent("NotThere.app")

        #expect(throws: UpdateError.self) {
            try UpdateInstaller.replaceBundle(at: target, withCopyOf: missing)
        }

        // 앱이 사라지는 것이 가장 나쁜 결과다.
        let marker = try Data(contentsOf: target.appendingPathComponent("marker.txt"))
        #expect(String(decoding: marker, as: UTF8.self) == "old")
    }
}

// MARK: - UpdateViewModel

/// 스위트가 `@MainActor`라 메서드로 두면 `@Sendable` 스텁 클로저 안에서 부를 수 없다.
private func makeRelease(_ version: String) -> AppRelease {
    AppRelease(
        version: SemanticVersion(version)!,
        dmgURL: URL(string: "https://example.invalid/a.dmg")!,
        checksumURL: URL(string: "https://example.invalid/a.dmg.sha256")!,
        pageURL: URL(string: "https://example.invalid/r")!
    )
}

@Suite("UpdateViewModel")
@MainActor
struct UpdateViewModelTests {
    private func viewModel(
        installed: String?,
        latest: @escaping @Sendable () async throws -> AppRelease,
        install: @escaping @Sendable (AppRelease) async throws -> URL = { _ in
            URL(fileURLWithPath: "/tmp/DiskTidy.app")
        },
        relaunch: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> UpdateViewModel {
        UpdateViewModel(
            installedVersion: installed.flatMap(SemanticVersion.init),
            fetchLatest: latest,
            install: install,
            relaunch: relaunch
        )
    }

    @Test("최신 버전이 더 높으면 버튼을 띄운다")
    func showsButtonWhenNewer() async {
        let model = viewModel(installed: "1.2.0", latest: { makeRelease("1.3.0") })

        await model.checkForUpdate()

        #expect(model.state == .available(makeRelease("1.3.0")))
        #expect(model.isButtonVisible)
    }

    @Test("같거나 낮은 버전이면 버튼을 감춘다")
    func hidesButtonWhenUpToDate() async {
        let same = viewModel(installed: "1.2.0", latest: { makeRelease("1.2.0") })
        await same.checkForUpdate()
        #expect(!same.isButtonVisible)

        let older = viewModel(installed: "1.2.0", latest: { makeRelease("1.1.9") })
        await older.checkForUpdate()
        #expect(!older.isButtonVisible)
    }

    @Test("번들 없이 실행하면 확인조차 하지 않는다")
    func skipsCheckWithoutBundle() async {
        // `swift run`으로 띄우면 교체할 `.app`이 없다.
        let model = viewModel(installed: nil, latest: {
            Issue.record("확인을 시도해서는 안 된다")
            return makeRelease("9.9.9")
        })

        await model.checkForUpdate()

        #expect(model.state == .idle)
    }

    @Test("확인 실패는 사유를 남기고 다시 시도할 수 있다")
    func recordsFailureAndAllowsRetry() async {
        let attempts = Counter()
        let model = viewModel(installed: "1.2.0", latest: {
            attempts.increment()
            if attempts.value == 1 { throw UpdateError.network("타임아웃") }
            return makeRelease("1.3.0")
        })

        await model.checkForUpdate()
        guard case .failed(let message) = model.state else {
            Issue.record("실패 상태여야 한다")
            return
        }
        #expect(message.contains("타임아웃"))

        // 실패 뒤에는 같은 버튼이 재확인 버튼이 된다.
        await model.checkForUpdate()
        #expect(model.state == .available(makeRelease("1.3.0")))
    }

    @Test("설치가 끝나면 교체된 번들로 재시작한다")
    func relaunchesAfterInstall() async {
        let bundle = URL(fileURLWithPath: "/Applications/DiskTidy.app")
        let relaunched = Box<URL?>(nil)
        let model = viewModel(
            installed: "1.2.0",
            latest: { makeRelease("1.3.0") },
            install: { _ in bundle },
            relaunch: { relaunched.value = $0 }
        )

        await model.checkForUpdate()
        await model.installUpdate()

        #expect(model.state == .restarting)
        #expect(relaunched.value == bundle)
    }

    @Test("설치가 실패하면 사유를 남기고 재시작하지 않는다")
    func keepsRunningWhenInstallFails() async {
        let relaunched = Box<URL?>(nil)
        let model = viewModel(
            installed: "1.2.0",
            latest: { makeRelease("1.3.0") },
            install: { _ in throw UpdateError.checksumMismatch },
            relaunch: { relaunched.value = $0 }
        )

        await model.checkForUpdate()
        await model.installUpdate()

        guard case .failed(let message) = model.state else {
            Issue.record("실패 상태여야 한다")
            return
        }
        #expect(message.contains("체크섬"))
        #expect(relaunched.value == nil)
    }

    @Test("확인 전에 설치를 부르면 아무 일도 없다")
    func installNeedsAvailableState() async {
        let model = viewModel(installed: "1.2.0", latest: { makeRelease("1.3.0") })

        await model.installUpdate()

        #expect(model.state == .idle)
    }
}

// MARK: - 테스트용 상자

/// 클로저 안에서 값을 바꿔 밖에서 확인하려면 참조가 필요하다.
/// 테스트는 한 스레드에서 순차로 돌므로 락을 두지 않는다.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
