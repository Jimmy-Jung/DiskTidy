// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskTidy",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 챗봇 답변 마크다운 렌더링. 스트리밍 증분 파싱과 블록을 넘는 텍스트 선택이
        // 필요해서 쓴다. 3.0.0이 갓 나온 버전이라 정확한 태그로 고정한다.
        .package(url: "https://github.com/LiYanan2004/MarkdownView.git", exact: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DiskTidy",
            dependencies: ["MarkdownView"],
            path: "Sources/DiskTidy"
        ),
        .testTarget(
            name: "DiskTidyTests",
            dependencies: ["DiskTidy"],
            path: "Tests/DiskTidyTests"
        ),
    ]
)
