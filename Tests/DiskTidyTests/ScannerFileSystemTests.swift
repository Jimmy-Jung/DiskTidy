import Foundation
import Testing

@testable import DiskTidy

// MARK: - CacheScanner

@Suite("CacheScanner")
struct CacheScannerTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("하위 항목을 크기 내림차순으로 돌려준다")
    func listsEntriesLargestFirst() throws {
        let caches = try temp.makeDirectory("Caches")
        try temp.makeFile("Caches/big/payload.bin", bytes: 256 * 1024)
        try temp.makeFile("Caches/small/payload.bin", bytes: 8 * 1024)
        try temp.makeDirectory("Caches/empty")

        let items = CacheScanner.scan(cachesURL: caches)

        #expect(items.map(\.name) == ["big", "small", "empty"])
        #expect(items[0].sizeBytes > items[1].sizeBytes)
        #expect(items[2].sizeBytes == 0)
    }

    @Test("디렉터리가 아닌 파일도 정리 후보에 포함한다")
    func includesLooseFiles() throws {
        let caches = try temp.makeDirectory("Caches")
        try temp.makeFile("Caches/loose.log", bytes: 4 * 1024)

        #expect(CacheScanner.scan(cachesURL: caches).map(\.name) == ["loose.log"])
    }

    @Test("없는 디렉터리는 빈 배열을 준다")
    func missingDirectoryGivesEmpty() {
        let missing = temp.url.appendingPathComponent("nope")
        #expect(CacheScanner.scan(cachesURL: missing).isEmpty)
    }

    @Test("기본 경로는 ~/Library/Caches다")
    func defaultPathPointsAtLibraryCaches() {
        #expect(CacheScanner.defaultCachesURL.path.hasSuffix("/Library/Caches"))
    }
}

// MARK: - XcodeCacheScanner

@Suite("XcodeCacheScanner")
struct XcodeCacheScannerTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("DerivedData · DeviceSupport · Archives를 라벨과 함께 모은다")
    func collectsLabeledEntries() throws {
        let dev = try temp.makeDirectory("Xcode")
        try temp.makeFile("Xcode/DerivedData/MyApp-abc/payload.bin", bytes: 128 * 1024)
        try temp.makeDirectory("Xcode/iOS DeviceSupport/18.0 (22A123)")
        try temp.makeDirectory("Xcode/watchOS DeviceSupport/11.0")
        try temp.makeDirectory("Xcode/tvOS DeviceSupport/18.0")
        try temp.makeDirectory("Xcode/Archives/2026-08-07/MyApp.xcarchive")

        let names = Set(XcodeCacheScanner.scan(devURL: dev).map(\.name))

        #expect(names == [
            "DerivedData/MyApp-abc",
            "iOS DeviceSupport/18.0 (22A123)",
            "watchOS DeviceSupport/11.0",
            "tvOS DeviceSupport/18.0",
            "Archives/2026-08-07/MyApp.xcarchive",
        ])
    }

    @Test("디렉터리가 아닌 항목은 후보에서 뺀다")
    func skipsNonDirectories() throws {
        let dev = try temp.makeDirectory("Xcode")
        try temp.makeFile("Xcode/DerivedData/.DS_Store", bytes: 16)
        try temp.makeDirectory("Xcode/DerivedData/RealApp-xyz")

        #expect(XcodeCacheScanner.scan(devURL: dev).map(\.name) == ["DerivedData/RealApp-xyz"])
    }

    @Test("Xcode 폴더가 없으면 빈 배열을 준다")
    func missingDevFolderGivesEmpty() {
        #expect(XcodeCacheScanner.scan(devURL: temp.url.appendingPathComponent("nope")).isEmpty)
    }

    @Test("기본 경로는 ~/Library/Developer/Xcode다")
    func defaultPathPointsAtXcodeFolder() {
        #expect(XcodeCacheScanner.defaultDevURL.path.hasSuffix("/Library/Developer/Xcode"))
    }
}

// MARK: - AndroidCacheScanner

@Suite("AndroidCacheScanner")
struct AndroidCacheScannerTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("존재하는 Gradle · Android 캐시만 라벨과 함께 모은다")
    func collectsExistingCachesOnly() throws {
        try temp.makeFile(".gradle/caches/payload.bin", bytes: 64 * 1024)
        try temp.makeDirectory(".android/cache")
        // .gradle/wrapper/dists 와 .android/build-cache 는 만들지 않는다.

        let names = Set(AndroidCacheScanner.scan(home: temp.url).map(\.name))

        #expect(names == ["Gradle 캐시", "Android 캐시"])
    }

    @Test("AndroidStudio 접두사 폴더의 caches를 찾아낸다")
    func findsAndroidStudioCaches() throws {
        try temp.makeDirectory("Library/Application Support/Google/AndroidStudio2026.1/caches")
        // 접두사가 다른 형제 폴더는 무시해야 한다.
        try temp.makeDirectory("Library/Application Support/Google/Chrome/caches")

        let names = AndroidCacheScanner.scan(home: temp.url).map(\.name)

        #expect(names == ["AndroidStudio2026.1/caches"])
    }

    @Test("캐시가 하나도 없으면 빈 배열을 준다")
    func emptyHomeGivesEmpty() {
        #expect(AndroidCacheScanner.scan(home: temp.url).isEmpty)
    }
}

// MARK: - AndroidEmulatorScanner

@Suite("AndroidEmulatorScanner")
struct AndroidEmulatorScannerTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test(".avd 디렉터리만 후보로 잡고 확장자를 뗀 이름을 쓴다")
    func listsAVDDirectoriesOnly() throws {
        let avdRoot = try temp.makeDirectory("avd")
        try temp.makeFile("avd/Pixel_9.avd/userdata.img", bytes: 128 * 1024)
        try temp.makeDirectory("avd/Pixel_8.avd")
        // 짝인 .ini 포인터 파일과 관계없는 폴더는 후보가 아니다.
        try temp.makeFile("avd/Pixel_9.ini", bytes: 32)
        try temp.makeDirectory("avd/snapshots")

        let items = AndroidEmulatorScanner.scan(avdRoot: avdRoot)

        #expect(items.map(\.name) == ["Pixel_9", "Pixel_8"])
        #expect(items[0].sizeBytes > items[1].sizeBytes)
    }

    @Test(".avd 이름의 파일은 디렉터리가 아니므로 뺀다")
    func skipsAVDNamedFile() throws {
        let avdRoot = try temp.makeDirectory("avd")
        try temp.makeFile("avd/Fake.avd", bytes: 16)

        #expect(AndroidEmulatorScanner.scan(avdRoot: avdRoot).isEmpty)
    }

    @Test("avd 폴더가 없으면 빈 배열을 준다")
    func missingRootGivesEmpty() {
        #expect(AndroidEmulatorScanner.scan(avdRoot: temp.url.appendingPathComponent("nope")).isEmpty)
    }

    @Test("iniURL은 AVD 이름 옆의 .ini 포인터를 가리킨다")
    func iniURLPointsAtSiblingFile() {
        let root = URL(fileURLWithPath: "/Users/dev/.android/avd")
        #expect(
            AndroidEmulatorScanner.iniURL(forAVDNamed: "Pixel_9", in: root).path
                == "/Users/dev/.android/avd/Pixel_9.ini"
        )
    }

    @Test("기본 AVD 경로는 ~/.android/avd다")
    func defaultRootPointsAtAVDFolder() {
        #expect(AndroidEmulatorScanner.defaultAVDRoot.path.hasSuffix("/.android/avd"))
    }
}

// MARK: - BigFileScanner.scan

@Suite("BigFileScanner.scan")
struct BigFileScannerTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("기준 크기 이상인 파일만 돌려준다")
    func filtersBySize() throws {
        try temp.makeFile("big.bin", bytes: 16 * 1024)
        try temp.makeFile("small.bin", bytes: 512)

        let items = BigFileScanner.scan(roots: [temp.url], minBytes: 8 * 1024)

        #expect(items.count == 1)
        #expect(items[0].path.lastPathComponent == "big.bin")
        #expect(items[0].sizeBytes == 16 * 1024)
    }

    @Test("maxDepth보다 깊은 파일은 찾지 않는다")
    func respectsMaxDepth() throws {
        try temp.makeFile("nested/deep.bin", bytes: 16 * 1024)

        let shallow = BigFileScanner.scan(roots: [temp.url], minBytes: 8 * 1024, maxDepth: 1)
        let deep = BigFileScanner.scan(roots: [temp.url], minBytes: 8 * 1024, maxDepth: 2)

        #expect(shallow.isEmpty)
        #expect(deep.map { $0.path.lastPathComponent } == ["deep.bin"])
    }

    @Test("공백과 개행이 든 파일 이름도 온전히 돌려준다")
    func handlesAwkwardFileNames() throws {
        let awkward = "we ird\nname.bin"
        try temp.makeFile(awkward, bytes: 16 * 1024)

        let items = BigFileScanner.scan(roots: [temp.url], minBytes: 8 * 1024)

        #expect(items.count == 1)
        #expect(items[0].path.lastPathComponent == awkward)
    }

    @Test("크기 내림차순으로 정렬한다")
    func sortsLargestFirst() throws {
        try temp.makeFile("a.bin", bytes: 16 * 1024)
        try temp.makeFile("b.bin", bytes: 64 * 1024)

        let names = BigFileScanner.scan(roots: [temp.url], minBytes: 8 * 1024)
            .map { $0.path.lastPathComponent }

        #expect(names == ["b.bin", "a.bin"])
    }

    @Test("없는 루트는 빈 배열을 준다")
    func missingRootGivesEmpty() {
        let missing = temp.url.appendingPathComponent("nope")
        #expect(BigFileScanner.scan(roots: [missing], minBytes: 1024).isEmpty)
    }
}

// MARK: - DiskScanner 추가 케이스

@Suite("DiskScanner 대량·특수 경로")
struct DiskScannerEdgeCaseTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("청크 상한(200)을 넘겨도 모든 경로를 측정한다")
    func measuresBeyondChunkLimit() throws {
        var dirs: [URL] = []
        for index in 0 ..< 205 {
            try temp.makeFile("d\(index)/payload.bin", bytes: 8 * 1024)
            dirs.append(temp.url.appendingPathComponent("d\(index)"))
        }

        let sizes = DiskScanner.sizes(of: dirs)

        #expect(sizes.count == 205)
        // 두 번째 청크(200번 이후)까지 실제로 측정됐는지 확인한다.
        #expect(sizes.values.allSatisfy { $0 >= 8 * 1024 })
    }

    @Test("공백과 탭이 든 경로도 크기를 맞춘다")
    func handlesWhitespaceInPaths() throws {
        // du 출력은 "크기\t경로" 형식이라 경로 안의 탭에서 파싱이 깨질 수 있다.
        try temp.makeFile("with space/payload.bin", bytes: 16 * 1024)
        try temp.makeFile("with\ttab/payload.bin", bytes: 16 * 1024)
        let dirs = ["with space", "with\ttab"].map(temp.url.appendingPathComponent)

        let sizes = DiskScanner.sizes(of: dirs)

        #expect(sizes[dirs[0]]! >= 16 * 1024)
        #expect(sizes[dirs[1]]! >= 16 * 1024)
    }

    @Test("sizeOfDirectory는 단일 경로 크기를 준다")
    func measuresSingleDirectory() throws {
        let dir = try temp.makeDirectory("single")
        try temp.makeFile("single/payload.bin", bytes: 32 * 1024)

        #expect(DiskScanner.sizeOfDirectory(dir) >= 32 * 1024)
    }

    @Test("chunked는 크기가 0 이하이면 통째로 돌려준다")
    func chunkedGuardsAgainstZeroSize() {
        #expect([1, 2, 3].chunked(into: 0) == [[1, 2, 3]])
    }
}

// MARK: - ProjectCacheScanner 재귀

@Suite("ProjectCacheScanner 재귀 탐색")
struct ProjectCacheRecursionTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("maxDepth보다 깊은 캐시는 찾지 않는다")
    func respectsMaxDepth() throws {
        try temp.makeDirectory("l1/l2/l3/Pods")

        let shallow = ProjectCacheScanner.scan(roots: [temp.url], maxDepth: 2)
        let deep = ProjectCacheScanner.scan(roots: [temp.url], maxDepth: 3)

        #expect(shallow.isEmpty)
        #expect(deep.count == 1)
        #expect(deep[0].path.lastPathComponent == "Pods")
    }

    @Test("캐시 디렉터리 안으로는 내려가지 않는다")
    func doesNotDescendIntoCaches() throws {
        try temp.makeFile("proj/package.json")
        try temp.makeDirectory("proj/node_modules/dep/Pods")

        let paths = ProjectCacheScanner.scan(roots: [temp.url]).map(\.path.lastPathComponent)

        // 중첩된 Pods까지 잡으면 같은 용량을 두 번 세고 삭제도 중복된다.
        #expect(paths == ["node_modules"])
    }

    @Test("상위를 가리키는 심볼릭 링크가 있어도 멈추지 않는다", .timeLimit(.minutes(1)))
    func survivesSymlinkCycle() throws {
        try temp.makeFile("proj/package.json")
        try temp.makeDirectory("proj/node_modules")
        try temp.makeSymbolicLink("proj/loop", to: temp.url)

        let paths = ProjectCacheScanner.scan(roots: [temp.url]).map(\.path.lastPathComponent)

        #expect(paths == ["node_modules"])
    }

    @Test("여러 루트를 한 번에 훑는다")
    func scansMultipleRoots() throws {
        let first = try temp.makeDirectory("first")
        let second = try temp.makeDirectory("second")
        try temp.makeDirectory("first/AppA/Pods")
        try temp.makeDirectory("second/AppB/DerivedData")

        let names = Set(ProjectCacheScanner.scan(roots: [first, second]).map(\.name))

        #expect(names == ["first/AppA/Pods", "second/AppB/DerivedData"])
    }

    @Test("루트가 없으면 빈 배열을 준다")
    func noRootsGivesEmpty() {
        #expect(ProjectCacheScanner.scan(roots: []).isEmpty)
    }

    @Test("allCacheDirNames는 고유 이름과 마커 게이트 이름을 모두 담는다")
    func allNamesUnionBothSets() {
        let all = ProjectCacheScanner.allCacheDirNames
        #expect(all.isSuperset(of: ProjectCacheScanner.unambiguousCacheDirNames))
        #expect(all.isSuperset(of: Set(ProjectCacheScanner.markerGatedCacheDirNames.keys)))
    }
}

// MARK: - FileAttributes

@Suite("FileAttributes")
struct FileAttributesTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("파일 크기를 바이트로 준다")
    func readsFileSize() throws {
        let file = try temp.makeFile("payload.bin", bytes: 4096)
        #expect(FileAttributes.size(of: file.path) == 4096)
    }

    @Test("없는 경로의 크기는 nil이다")
    func missingPathSizeIsNil() {
        #expect(FileAttributes.size(of: temp.url.appendingPathComponent("nope").path) == nil)
    }

    @Test("설정한 수정일을 그대로 읽는다")
    func readsModificationDate() throws {
        let file = try temp.makeFile("dated.bin")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try temp.setModificationDate(stamp, of: file)

        let read = try #require(FileAttributes.modificationDate(of: file))
        #expect(abs(read.timeIntervalSince(stamp)) < 1)
    }

    @Test("없는 경로의 수정일은 nil이다")
    func missingPathDateIsNil() {
        #expect(FileAttributes.modificationDate(of: temp.url.appendingPathComponent("nope")) == nil)
    }
}

// MARK: - 심볼릭 링크로 걸린 스캔 루트

/// `FileManager.contentsOfDirectory(at:)`(URL 버전)는 심볼릭 링크 디렉터리에서
/// `ENOTDIR`로 실패한다. `~/Library/Developer/Xcode/DerivedData`를 외장 디스크로
/// 빼 두면 Xcode 캐시 화면이 통째로 비어 보였다 — 그 회귀를 막는다.
@Suite("심볼릭 링크로 걸린 스캔 루트")
struct SymlinkedScanRootTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("캐시 루트가 링크여도 하위 항목을 읽는다")
    func cacheRootThroughSymlink() throws {
        try temp.makeFile("real/big/payload.bin", bytes: 64 * 1024)
        try temp.makeSymbolicLink("link", to: temp.url.appendingPathComponent("real"))

        let items = CacheScanner.scan(cachesURL: temp.url.appendingPathComponent("link"))

        #expect(items.map(\.name) == ["big"])
        #expect(items[0].sizeBytes > 0)
    }

    @Test("DerivedData가 링크여도 하위 항목을 읽는다")
    func derivedDataThroughSymlink() throws {
        let dev = try temp.makeDirectory("Xcode")
        try temp.makeFile("elsewhere/RealApp-xyz/payload.bin", bytes: 32 * 1024)
        try FileManager.default.createSymbolicLink(
            at: dev.appendingPathComponent("DerivedData"),
            withDestinationURL: temp.url.appendingPathComponent("elsewhere")
        )

        #expect(XcodeCacheScanner.scan(devURL: dev).map(\.name) == ["DerivedData/RealApp-xyz"])
    }

    @Test("프로젝트 캐시 루트가 링크여도 빌드 캐시를 찾는다")
    func projectRootThroughSymlink() throws {
        try temp.makeFile("real/MyApp/Package.swift", bytes: 16)
        try temp.makeFile("real/MyApp/.build/payload.bin", bytes: 16 * 1024)
        try temp.makeSymbolicLink("link", to: temp.url.appendingPathComponent("real"))

        let items = ProjectCacheScanner.scan(roots: [temp.url.appendingPathComponent("link")])

        // 표시 이름은 루트의 부모 기준이라 루트 이름까지 들어간다. 링크를 푼 뒤라
        // 링크 이름(`link`)이 아니라 실제 폴더 이름(`real`)이 보인다.
        #expect(items.map(\.name) == ["real/MyApp/.build"])
    }

    @Test("삭제 대상은 링크가 아니라 실경로다")
    func resolvedPathPointsAtRealTarget() throws {
        let real = try temp.makeDirectory("real")
        try temp.makeFile("real/big/payload.bin", bytes: 8 * 1024)
        try temp.makeSymbolicLink("link", to: real)

        let item = try #require(
            CacheScanner.scan(cachesURL: temp.url.appendingPathComponent("link")).first
        )

        // 링크만 지우면 공간이 회수되지 않는다. 실경로를 들고 있어야 한다.
        // `/private` 접두사는 비교하지 않는다 — `resolvingSymlinksInPath()`는 떼고
        // `contentsOfDirectory`는 붙여 줘서 경로 문자열이 그대로는 안 맞는다.
        #expect(!item.path.path.contains("/link/"))
        #expect(item.path.path.hasSuffix("/real/big"))
    }
}
