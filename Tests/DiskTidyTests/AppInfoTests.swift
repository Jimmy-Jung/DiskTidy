import Foundation
import Testing

@testable import DiskTidy

@Suite("AppInfo")
struct AppInfoTests {
    /// 버전은 두 곳에 산다 — Info.plist(번들 실행)와 `AppInfo.version`(맨 바이너리 실행).
    /// 한쪽만 올리면 배포 빌드와 개발 빌드가 다른 버전을 말하게 되므로 여기서 묶는다.
    @Test("AppInfo.version은 Info.plist의 CFBundleShortVersionString과 같다")
    func versionMatchesInfoPlist() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppInfoTests.swift
            .deletingLastPathComponent() // DiskTidyTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plistVersion = try #require(
            (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
        )
        #expect(AppInfo.version == plistVersion)
    }
}
