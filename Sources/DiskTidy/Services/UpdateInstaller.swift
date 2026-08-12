import CryptoKit
import Foundation

/// 릴리스 DMG를 내려받아 검증하고, 실행 중인 앱 번들을 그 안의 번들로 교체한다.
///
/// 실행 중인 자기 번들을 바꿀 수 있는 이유: macOS는 이미 매핑된 실행 이미지를 inode로
/// 붙들고 있어서, 번들을 옮기거나 지워도 지금 돌고 있는 프로세스는 살아 있다. 다만 그
/// 뒤로 디스크에서 리소스를 새로 읽으면 실패하므로 교체 직후 곧바로 재시작해야 한다.
enum UpdateInstaller {
    /// 다운로드 → 검증 → 마운트 → 교체까지. 재시작은 호출자가 결정한다.
    ///
    /// - Returns: 교체가 끝난 앱 번들 경로. 재시작할 때 이 경로를 연다.
    static func install(_ release: AppRelease, session: URLSession = .shared) async throws -> URL {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        // 교체 불가를 미리 알린다. 다 내려받은 뒤 마지막 단계에서 막히면 시간만 버린다.
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notReplaceable(parent.path)
        }

        // ponytail: DMG가 10MB 안쪽이라 통째로 메모리에 받고 진행률을 만들지 않는다.
        // 배포물이 커지면 `URLSession.bytes(for:)`로 바꿔 누적 바이트를 흘려주면 된다.
        let dmgData = try await download(release.dmgURL, session: session)
        let checksumText = try await download(release.checksumURL, session: session)

        guard let expected = expectedChecksum(from: String(decoding: checksumText, as: UTF8.self)),
              sha256Hex(of: dmgData) == expected
        else { throw UpdateError.checksumMismatch }

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskTidyUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let dmg = workspace.appendingPathComponent(release.dmgURL.lastPathComponent)
        try dmgData.write(to: dmg)

        let mountPoint = workspace.appendingPathComponent("mount")
        try mount(dmg, at: mountPoint)
        defer { ShellRunner.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let source = mountPoint.appendingPathComponent(target.lastPathComponent)
        try verify(bundleAt: source)
        try replaceBundle(at: target, withCopyOf: source)
        return target
    }

    // MARK: - 단계별 조각 (테스트가 여기까지 들어온다)

    /// `shasum -a 256` 출력에서 해시만 뽑는다. 형식은 `<64자 hex>  <파일명>`.
    static func expectedChecksum(from text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let field = line.split(separator: " ", omittingEmptySubsequences: true).first
            else { continue }
            let candidate = field.lowercased()
            guard candidate.count == 64, candidate.allSatisfy(\.isHexDigit) else { continue }
            return candidate
        }
        return nil
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 번들이 우리 앱인지 확인한다.
    ///
    /// ad-hoc 서명이라 `codesign`이 출처를 증명해 주지는 않는다. 그래도 통과시키는 이유는
    /// 전송·압축 해제 중 깨진 번들을 여기서 걸러내기 때문이다. 출처 검증은 체크섬이 한다.
    static func verify(bundleAt url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              ShellRunner.run("/usr/bin/codesign", ["--verify", "--strict", url.path]).succeeded
        else { throw UpdateError.bundleMismatch }
    }

    /// 기존 번들을 같은 볼륨 안에서 이름만 바꿔 치워 두고 새 번들을 그 자리에 복사한다.
    /// 복사가 실패하면 치워 둔 것을 되돌린다 — 앱이 사라지는 것이 가장 나쁜 결과다.
    static func replaceBundle(at target: URL, withCopyOf source: URL) throws {
        let manager = FileManager.default
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).backup-\(UUID().uuidString)")

        do {
            try manager.moveItem(at: target, to: backup)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }

        do {
            try manager.copyItem(at: source, to: target)
        } catch {
            try? manager.removeItem(at: target)
            try? manager.moveItem(at: backup, to: target)
            throw UpdateError.installFailed(error.localizedDescription)
        }

        // 공증을 받지 않은 번들이라 quarantine 표시가 남으면 Gatekeeper가 재실행을 막는다.
        // 사용자가 이미 실행 중인 앱을 갱신한 것이므로 여기서 떼어 준다.
        ShellRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        try? manager.removeItem(at: backup)
    }

    /// 우리가 죽는 것을 지켜보다 새 앱을 여는 셸을 띄운다.
    ///
    /// `open`은 같은 번들 ID가 이미 돌고 있으면 새 인스턴스를 만들지 않고 그 앱을 앞으로
    /// 가져오기만 한다. 그래서 우리가 먼저 사라져야 하고, 그 시점에는 `open`을 부를 주체가
    /// 남지 않는다. 짧은 감시 셸이 그 자리를 메운다.
    static func scheduleRelaunch(of bundleURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quoted = "'" + bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec open -n \(quoted)",
        ]
        // 기다리지 않는다. 부모가 종료돼도 자식은 launchd가 이어받아 계속 산다.
        try? process.run()
    }

    // MARK: - 내부

    private static func download(_ url: URL, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw UpdateError.network("HTTP \(http.statusCode) — \(url.lastPathComponent)")
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }

    private static func mount(_ dmg: URL, at mountPoint: URL) throws {
        // `-nobrowse`로 Finder 사이드바에 띄우지 않고, `-readonly`로 이미지를 건드리지 않는다.
        let result = ShellRunner.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path,
        ])
        guard result.succeeded else { throw UpdateError.mountFailed }
    }
}
