// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskTidy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DiskTidy",
            path: "Sources/DiskTidy"
        ),
        .testTarget(
            name: "DiskTidyTests",
            dependencies: ["DiskTidy"],
            path: "Tests/DiskTidyTests"
        ),
    ]
)
