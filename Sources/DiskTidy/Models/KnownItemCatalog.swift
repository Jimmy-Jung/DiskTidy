import Foundation

/// 이 앱이 스스로 아는 항목의 설명.
///
/// 목록에 들어온 경로는 대부분 **앱이 찾아서 넣은 것**이다. Android 캐시 탭은
/// `~/.gradle/caches`를 Gradle 캐시로 알고 넣는다. 그런 항목의 정체를 AI에게 다시 묻는 것은
/// 느리고(첫 요청마다 프로세스 하나) 비싸고(제공자 쿼터) 덜 정확하다 — 모델은 경로만 보고
/// 추측하지만 여기 적힌 것은 스캐너가 실제로 노리는 대상이다.
///
/// 그래서 아는 것은 즉시 답하고, 모르는 것만 AI에게 넘긴다. AI가 실제로 필요한 곳은
/// 대용량 파일·임시파일 탭의 낯선 경로와 처음 보는 프로세스다.
enum KnownItemCatalog {
    /// 경로 조각과 설명. **위에서부터 먼저 맞는 것을 쓴다** — 좁은 규칙을 먼저 둔다.
    /// (`/.gradle/caches`가 `/Library/Caches`보다, `Archives`가 `DerivedData`보다 앞이다.)
    private static let rules: [(fragment: String, description: String)] = [
        // MARK: Xcode
        (
            "/Library/Developer/Xcode/Archives",
            "Xcode가 만든 아카이브입니다. 배포한 빌드와 그 dSYM(크래시 로그를 사람이 읽는 "
                + "형태로 되살리는 심볼)이 들어 있어, 지우면 이미 내보낸 버전의 크래시를 해석할 수 "
                + "없게 됩니다. 다시 만들 수 없으니 배포 중인 버전은 남겨 두세요."
        ),
        (
            "/Library/Developer/Xcode/DerivedData",
            "Xcode의 빌드 산출물과 인덱스입니다. 지워도 됩니다 — 다음 빌드에서 다시 만들어지며, "
                + "그 한 번은 전체 빌드가 되어 오래 걸립니다."
        ),
        (
            "DeviceSupport",
            "Xcode가 연결된 실기기에서 가져온 OS 심볼입니다. 지워도 됩니다 — 그 버전의 기기를 "
                + "다시 연결하면 Xcode가 다시 받아옵니다(수 분 걸립니다)."
        ),
        (
            "/Library/Developer/XCTestDevices",
            "Xcode가 병렬 테스트 때 만드는 시뮬레이터 클론입니다. 테스트가 끝나도 자동으로 "
                + "지워지지 않아 수백 GB까지 쌓입니다. 지워도 됩니다 — 다음 병렬 테스트에서 "
                + "다시 만들어집니다."
        ),
        (
            "/Library/Developer/CoreSimulator",
            "iOS 시뮬레이터의 기기 데이터와 캐시입니다. 지우면 시뮬레이터에 설치한 앱과 그 안의 "
                + "데이터·로그인 상태가 사라집니다. 기기 자체는 다시 만들어집니다."
        ),

        // MARK: 패키지 매니저 전역 캐시 (GlobalCacheScanner가 노리는 경로들)
        (
            "/.npm/_cacache",
            "npm이 내려받은 패키지 압축본 캐시입니다. 지워도 됩니다 — 다음 `npm install`에서 "
                + "필요한 것만 다시 내려받습니다."
        ),
        (
            "/.cocoapods/repos",
            "CocoaPods의 스펙 저장소 캐시입니다. 지워도 됩니다 — 다음 `pod install`에서 CDN을 "
                + "통해 다시 받아옵니다."
        ),
        (
            "/Library/Caches/org.swift.swiftpm",
            "Swift Package Manager가 내려받은 패키지 캐시입니다. 지워도 됩니다 — 다음 패키지 "
                + "해석 때 다시 내려받습니다."
        ),
        (
            "/Library/pnpm/store",
            "pnpm의 콘텐츠 주소 저장소입니다. 지워도 됩니다 — 다음 설치에서 다시 내려받지만 "
                + "모든 pnpm 프로젝트가 공유하는 저장소라 첫 설치가 오래 걸립니다."
        ),
        (
            "/.bun/install/cache",
            "Bun이 내려받은 패키지 캐시입니다. 지워도 됩니다 — 다음 `bun install`에서 다시 "
                + "내려받습니다."
        ),
        (
            "/.cargo/registry",
            "Cargo(Rust)가 내려받은 크레이트 레지스트리입니다. 지워도 됩니다 — 다음 빌드에서 "
                + "다시 내려받습니다."
        ),
        (
            "/Library/Caches/pip",
            "pip이 내려받은 파이썬 패키지 캐시입니다. 지워도 됩니다 — 다음 설치에서 다시 "
                + "내려받습니다."
        ),
        (
            "/Library/Caches/uv",
            "uv(파이썬 패키지 매니저)의 캐시입니다. 지워도 됩니다 — 다음 설치에서 다시 "
                + "내려받습니다."
        ),

        // MARK: Gradle · Android
        (
            "/.gradle/wrapper/dists",
            "Gradle Wrapper가 내려받은 Gradle 배포판입니다. 프로젝트가 요구하는 버전을 다시 "
                + "내려받으므로 지워도 되지만, 다음 빌드에 인터넷이 필요합니다."
        ),
        (
            "/.gradle/caches",
            "Gradle이 내려받은 의존성과 빌드 캐시입니다. 지워도 됩니다 — 다음 빌드에서 필요한 "
                + "것만 다시 내려받고, 그동안 빌드가 느려지며 인터넷이 필요합니다."
        ),
        (
            "/.android/build-cache",
            "Android Gradle 플러그인의 빌드 캐시입니다. 지워도 됩니다 — 다음 빌드에서 다시 "
                + "만들어지고 그 한 번만 느려집니다."
        ),
        (
            "/.android/avd",
            "Android 에뮬레이터 기기(AVD)의 디스크 이미지입니다. 지우면 그 에뮬레이터에 설치한 "
                + "앱과 데이터가 사라집니다. 기기는 AVD Manager에서 다시 만들 수 있습니다."
        ),

        // MARK: 프로젝트 폴더 (ProjectCacheScanner가 노리는 이름들)
        (
            "node_modules",
            "npm·yarn·pnpm이 설치한 프로젝트 의존성입니다. 지워도 됩니다 — 잠금 파일이 있으면 "
                + "`npm ci` 같은 명령으로 같은 버전이 그대로 복원됩니다(인터넷 필요)."
        ),
        (
            "Pods",
            "CocoaPods가 설치한 의존성 소스입니다. `Podfile.lock`이 있으면 `pod install`로 같은 "
                + "버전이 복원되므로 지워도 됩니다."
        ),
        (
            "Carthage",
            "Carthage가 빌드한 의존성 프레임워크입니다. `Cartfile.resolved`가 있으면 다시 빌드해 "
                + "복원할 수 있습니다(빌드 시간이 걸립니다)."
        ),
        (
            ".dart_tool",
            "Flutter·Dart의 빌드 메타데이터와 패키지 해석 결과입니다. 지워도 됩니다 — "
                + "`flutter pub get`이나 다음 빌드에서 다시 만들어집니다."
        ),
        (
            ".next",
            "Next.js의 빌드 산출물입니다. 지워도 됩니다 — 다음 빌드에서 다시 만들어집니다."
        ),
        (
            ".expo",
            "Expo의 로컬 캐시입니다. 지워도 됩니다 — 다음 실행에서 다시 만들어집니다."
        ),

        // MARK: 에이전트 작업물 (TempScanner가 출처를 아는 tmp 항목)
        (
            "tmp/claude-",
            "Claude Code 세션이 작업하며 임시로 쓴 스크래치 폴더입니다(스크립트·중간 결과·백그라운드 "
                + "작업 출력). 세션이 끝나면 다시 쓰이지 않고, 세션을 재개해도 스크래치는 새로 만들어집니다. "
                + "목록에 오른 것은 그 세션의 프로세스가 없고 30분 넘게 변경이 없는 것입니다."
        ),
        (
            "tmp/codex-dd-",
            "Codex가 빌드·테스트를 돌리며 `xcodebuild -derivedDataPath`로 만든 DerivedData입니다. "
                + "지워도 됩니다 — 다음 빌드에서 다시 만들어지며, 그 한 번은 전체 빌드가 되어 오래 걸립니다."
        ),
        (
            "/.com.openai.codex.",
            "Codex 앱 서버가 풀어 둔 임시 리소스 파일입니다. 지워도 됩니다 — 필요하면 다시 만듭니다."
        ),

        // MARK: 시스템 캐시
        (
            "/Library/Caches/Homebrew",
            "Homebrew가 내려받은 설치 파일 캐시입니다. 지워도 됩니다 — 다시 설치할 때 "
                + "다시 내려받습니다."
        ),
        (
            "/Library/Caches",
            "앱들이 다시 만들 수 있는 데이터를 두는 캐시 폴더입니다. 대개 지워도 되지만, 앱이 "
                + "여기에 캐시가 아닌 것을 두는 경우가 있어 해당 앱을 종료한 뒤 지우는 편이 안전합니다."
        ),
    ]

    /// 실행 파일 이름으로 아는 프로세스.
    ///
    /// 개발 데몬 탭에는 macOS가 늘 띄우는 시스템 데몬과 개발 도구가 섞여 나온다. 이름이 곧
    /// 정체인 것들이라 AI에게 물을 이유가 없다 — 3B 온디바이스 모델이든 클라우드든 여기 적힌
    /// 것보다 정확할 수 없다.
    ///
    /// 접두사로 맞춘다. `mdworker_shared`처럼 뒤에 붙는 변형이 많다. **좁은 접두사를 먼저**
    /// 둔다(`mdworker`가 `mds`보다 앞).
    private static let processRules: [(prefix: String, description: String)] = [
        (
            "remotemanagementd",
            "macOS의 원격 관리 데몬입니다. 화면 공유·원격 로그인·MDM 관리 기능이 쓰며 시스템이 "
                + "필요할 때 다시 띄웁니다. 개발과 무관하니 그냥 두세요."
        ),
        (
            "mdworker",
            "Spotlight 색인 작업자입니다. 종료해도 시스템이 다시 띄우며, 색인이 처음부터 돌면 "
                + "CPU와 디스크를 더 씁니다."
        ),
        (
            "mds",
            "Spotlight 색인 프로세스입니다. 종료해도 시스템이 곧 다시 띄우고, 색인이 다시 돌면서 "
                + "오히려 더 바빠집니다. 큰 폴더를 지운 직후라면 잦아들 때까지 두세요."
        ),
        (
            "windowserver",
            "화면을 그리는 macOS 핵심 프로세스입니다. 종료하면 로그아웃됩니다. 메모리를 많이 "
                + "쓰는 것이 정상이며 손대지 마세요."
        ),
        (
            "kernel_task",
            "커널 자신입니다. 종료할 수 없고, 여기 잡히는 메모리는 커널이 관리하는 몫입니다."
        ),
        (
            "launchd",
            "macOS의 모든 프로세스를 띄우는 최상위 데몬(PID 1)입니다. 종료할 수 없습니다."
        ),
        (
            "gradle",
            "Gradle 빌드 데몬입니다. 빌드를 빠르게 하려고 상주하며, 종료해도 다음 빌드에서 다시 "
                + "뜹니다(그 빌드만 느려집니다). 안 쓰는 프로젝트의 데몬이면 종료해도 잃는 것이 없습니다."
        ),
        (
            "kotlin",
            "Kotlin 컴파일 데몬입니다. 종료해도 다음 빌드에서 다시 뜨며 그 빌드만 느려집니다."
        ),
        (
            "adb",
            "Android Debug Bridge 서버입니다. 종료하면 연결된 기기·에뮬레이터 세션이 끊기지만 "
                + "다음 `adb` 명령이나 Android Studio가 다시 띄웁니다."
        ),
        (
            "dart",
            "Dart·Flutter 도구 프로세스입니다. 이름이 dart인 것 대부분은 Claude Code·Codex 같은 에이전트가 "
                + "세션마다 하나씩 띄우는 Dart MCP 서버(`dart mcp-server`)이고, VS Code Dart 확장의 분석 서버·"
                + "도구 데몬·DevTools도 여기 잡힙니다. MCP 서버는 그 에이전트 세션이 끝나면 함께 사라지고, "
                + "분석 서버는 에디터가 다시 띄웁니다. 실행 중인 앱이면 종료 시 저장하지 않은 상태를 잃습니다."
        ),
        (
            "node",
            "Node.js 프로세스입니다. 개발 서버·번들러·MCP 서버 등 무엇이든일 수 있어 이름만으로는 "
                + "정체를 확정할 수 없습니다. 종료하면 그 프로세스가 하던 작업이 끊기므로, 무엇인지 "
                + "모르겠다면 두는 편이 안전합니다."
        ),
        (
            "java",
            "JVM 프로세스입니다. 빌드 도구나 IDE가 띄운 것이 대부분이지만 이름만으로는 정체를 "
                + "확정할 수 없습니다. 종료하면 그 작업이 끊깁니다."
        ),
    ]

    /// 앱이 아는 프로세스면 설명을, 모르면 `nil`.
    static func description(forProcessNamed name: String) -> String? {
        let lowered = name.lowercased()
        return processRules.first { lowered.hasPrefix($0.prefix) }?.description
    }

    /// 앱이 아는 항목이면 설명을, 모르면 `nil`.
    static func description(for path: URL) -> String? {
        let fullPath = path.path
        // 폴더 이름이 규칙과 정확히 같은 경우(`.../MyProject/node_modules`)도 잡아야 한다.
        let lastComponent = path.lastPathComponent
        return rules.first { rule in
            fullPath.contains(rule.fragment) || lastComponent == rule.fragment
        }?.description
    }
}
