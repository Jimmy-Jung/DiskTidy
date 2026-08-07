import Foundation
import Testing

@testable import DiskTidy

// MARK: - ProjectCacheScanner 마커 게이트

/// 마커 게이트가 없으면 커밋된 `dist` · `build` · `target` 소스 디렉터리를
/// 빌드 캐시로 오인해 휴지통으로 보낸다. 이 스위트가 그 회귀를 잡는다.
@Suite("ProjectCacheScanner 마커 게이트")
struct ProjectCacheMarkerGateTests {
    private let fixture: URL

    init() throws {
        fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskTidyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    private func makeProject(named name: String, marker: String?, cacheDir: String) throws -> URL {
        let project = fixture.appendingPathComponent(name)
        let cache = project.appendingPathComponent(cacheDir)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let marker {
            try Data().write(to: project.appendingPathComponent(marker))
        }
        return cache
    }

    @Test("마커가 있으면 캐시로 인정한다", arguments: [
        ("node_modules", "package.json"),
        ("dist", "package.json"),
        ("target", "Cargo.toml"),
        ("build", "CMakeLists.txt"),
        (".build", "Package.swift"),
    ])
    func acceptsWithMarker(cacheDir: String, marker: String) throws {
        let cache = try makeProject(named: "with-\(marker)", marker: marker, cacheDir: cacheDir)
        #expect(ProjectCacheScanner.isCacheDirectory(cache))
    }

    @Test("마커가 없으면 캐시로 인정하지 않는다", arguments: [
        "node_modules", "dist", "target", "build", ".build",
    ])
    func rejectsWithoutMarker(cacheDir: String) throws {
        let cache = try makeProject(named: "bare-\(cacheDir)", marker: nil, cacheDir: cacheDir)
        #expect(!ProjectCacheScanner.isCacheDirectory(cache))
    }

    @Test("이름이 고유한 캐시는 마커 없이 통과한다", arguments: [
        "Pods", "DerivedData", ".gradle", "Carthage", ".dart_tool", ".next", ".expo",
    ])
    func acceptsUnambiguousNames(cacheDir: String) throws {
        let cache = try makeProject(named: "unambiguous-\(cacheDir)", marker: nil, cacheDir: cacheDir)
        #expect(ProjectCacheScanner.isCacheDirectory(cache))
    }

    @Test("캐시 이름이 아니면 거부한다")
    func rejectsUnknownName() throws {
        let dir = try makeProject(named: "src-project", marker: "package.json", cacheDir: "src")
        #expect(!ProjectCacheScanner.isCacheDirectory(dir))
    }

    @Test("scan은 마커 없는 dist를 결과에서 뺀다")
    func scanSkipsMarkerlessDist() throws {
        let root = fixture.appendingPathComponent("roots")
        let real = root.appendingPathComponent("real-node-project")
        let fake = root.appendingPathComponent("static-site")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(
            at: fake.appendingPathComponent("dist"), withIntermediateDirectories: true)

        let names = ProjectCacheScanner.scan(roots: [root]).map(\.name)
        #expect(names.contains { $0.hasSuffix("real-node-project/dist") })
        #expect(!names.contains { $0.hasSuffix("static-site/dist") })
    }

    @Test("displayName은 루트의 부모를 기준으로 상대 경로를 만든다")
    func displayNameIsRelativeToRootParent() {
        let root = URL(fileURLWithPath: "/Users/dev/Projects")
        let cache = URL(fileURLWithPath: "/Users/dev/Projects/MyApp/node_modules")
        #expect(ProjectCacheScanner.displayName(for: cache, roots: [root]) == "Projects/MyApp/node_modules")
    }

    @Test("루트 밖의 경로는 절대 경로 그대로 보여준다")
    func displayNameFallsBackToAbsolutePath() {
        let root = URL(fileURLWithPath: "/Users/dev/Projects")
        let outside = URL(fileURLWithPath: "/opt/other/node_modules")
        #expect(ProjectCacheScanner.displayName(for: outside, roots: [root]) == "/opt/other/node_modules")
    }
}

// MARK: - DiskScanner

@Suite("DiskScanner")
struct DiskScannerTests {
    @Test("여러 경로를 한 번에 측정한다")
    func measuresMultiplePathsInOneCall() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskTidyTests-\(UUID().uuidString)")
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64 * 1024).write(to: first.appendingPathComponent("payload.bin"))

        let sizes = DiskScanner.sizes(of: [first, second])
        #expect(sizes.count == 2)
        #expect(sizes[first]! >= 64 * 1024)
        #expect(sizes[second]! < 64 * 1024)
    }

    @Test("빈 입력은 프로세스를 띄우지 않고 빈 결과를 준다")
    func emptyInputReturnsEmpty() {
        #expect(DiskScanner.sizes(of: []).isEmpty)
    }

    @Test("존재하지 않는 경로는 0을 준다")
    func missingPathIsZero() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DiskScanner.sizes(of: [missing])[missing] == 0)
    }

    @Test("chunked는 원소를 잃지 않는다")
    func chunkedPreservesElements() {
        let input = Array(1 ... 450)
        let chunks = input.chunked(into: 200)
        #expect(chunks.count == 3)
        #expect(chunks.flatMap { $0 } == input)
    }
}

// MARK: - ShellRunner

@Suite("ShellRunner")
struct ShellRunnerTests {
    @Test("stderr를 대량으로 쓰는 자식 프로세스에서 멈추지 않는다", .timeLimit(.minutes(1)))
    func doesNotDeadlockOnLargeStderr() {
        // stderr를 Pipe로 두면 버퍼(64KB)가 차는 순간 영구 대기에 빠졌던 회귀.
        let script = "for i in $(seq 1 20000); do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1>&2; done; echo ok"
        let result = ShellRunner.run("/bin/sh", ["-c", script])
        #expect(result.succeeded)
        #expect(result.output.contains("ok"))
    }

    @Test("실패한 명령의 종료 코드를 돌려준다")
    func reportsFailureExitCode() {
        let result = ShellRunner.run("/bin/sh", ["-c", "exit 3"])
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
    }

    @Test("실행 파일이 없으면 -1을 돌려준다")
    func missingExecutableReportsMinusOne() {
        let result = ShellRunner.run("/nonexistent/binary", [])
        #expect(result.exitCode == -1)
        #expect(!result.succeeded)
    }
}

// MARK: - SimulatorManager

@Suite("SimulatorManager.shortRuntimeName")
struct RuntimeNameTests {
    @Test("런타임 식별자를 사람이 읽는 이름으로 바꾼다", arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "iOS 26.5"),
        ("com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "watchOS 11.0"),
        ("com.apple.CoreSimulator.SimRuntime.tvOS-18-1-1", "tvOS 18.1.1"),
    ])
    func formatsKnownRuntimes(key: String, expected: String) {
        #expect(SimulatorManager.shortRuntimeName(key) == expected)
    }

    @Test("버전이 없는 식별자는 그대로 돌려준다")
    func passesThroughVersionlessKey() {
        #expect(SimulatorManager.shortRuntimeName("com.apple.CoreSimulator.SimRuntime.unknown") == "unknown")
    }

    @Test("점이 없는 문자열도 크래시 없이 처리한다")
    func handlesPlainString() {
        #expect(SimulatorManager.shortRuntimeName("iOS-26-5") == "iOS 26.5")
    }
}

// MARK: - BigFileScanner

@Suite("BigFileScanner.displayName")
struct BigFileDisplayNameTests {
    @Test("홈 디렉터리 경로를 물결표로 줄인다")
    func abbreviatesHomePath() {
        let name = BigFileScanner.displayName(
            for: "/Users/dev/Downloads/huge.zip", homePath: "/Users/dev")
        #expect(name == "~/Downloads/huge.zip")
    }

    @Test("홈 밖의 경로는 그대로 둔다")
    func keepsPathOutsideHome() {
        let name = BigFileScanner.displayName(for: "/opt/data/huge.zip", homePath: "/Users/dev")
        #expect(name == "/opt/data/huge.zip")
    }
}
