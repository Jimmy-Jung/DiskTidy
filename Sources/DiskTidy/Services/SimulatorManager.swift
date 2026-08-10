import Foundation

private struct SimctlDeviceList: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
}

/// `simctl list devices -j`에서 뽑아낸 기기 한 대. 디스크 접근 전의 순수 데이터라
/// 파싱 규칙만 따로 검증할 수 있다.
struct SimulatorEntry: Equatable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
}

enum SimulatorManager {
    static var defaultDevicesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    }

    static func listDevices() -> [SimulatorItem] {
        let result = ShellRunner.runXcrun(["simctl", "list", "devices", "-j"])
        guard result.succeeded, let data = result.output.data(using: .utf8) else { return [] }
        return makeItems(from: parseDevices(data), devicesRoot: defaultDevicesRoot)
    }

    /// 런타임이 삭제된 고아 기기는 simctl이 isAvailable=false로 표시한다.
    /// 실체가 없어 삭제도 안 되므로 목록에서 뺀다.
    static func parseDevices(_ data: Data) -> [SimulatorEntry] {
        guard let list = try? JSONDecoder().decode(SimctlDeviceList.self, from: data) else { return [] }
        return list.devices.flatMap { runtimeKey, devices in
            devices
                .filter { $0.isAvailable ?? true }
                .map {
                    SimulatorEntry(
                        udid: $0.udid,
                        name: $0.name,
                        runtime: shortRuntimeName(runtimeKey),
                        state: $0.state
                    )
                }
        }
    }

    /// 마지막 사용 시각은 기기 디렉터리 자체보다 `data/Library/Preferences`가 정확하다.
    /// 부팅한 적 없는 기기에는 그 경로가 없으므로 기기 디렉터리로 물러난다.
    static func makeItems(from entries: [SimulatorEntry], devicesRoot: URL) -> [SimulatorItem] {
        let deviceURLs = entries.map { devicesRoot.appendingPathComponent($0.udid) }
        let sizes = DiskScanner.sizes(of: deviceURLs)

        return entries
            .map { entry in
                let deviceURL = devicesRoot.appendingPathComponent(entry.udid)
                return SimulatorItem(
                    id: entry.udid,
                    name: entry.name,
                    runtime: entry.runtime,
                    state: entry.state,
                    sizeBytes: sizes[deviceURL] ?? 0,
                    lastUsed: FileAttributes.modificationDate(
                        of: deviceURL.appendingPathComponent("data/Library/Preferences")
                    ) ?? FileAttributes.modificationDate(of: deviceURL)
                )
            }
            .sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    }

    /// com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> "iOS 26.5"
    static func shortRuntimeName(_ key: String) -> String {
        guard let last = key.split(separator: ".").last else { return key }
        let comps = last.split(separator: "-")
        guard comps.count >= 2 else { return String(last) }
        return "\(comps[0]) \(comps.dropFirst().joined(separator: "."))"
    }

    /// 삭제/초기화는 실패할 수 있다 (부팅 중인 기기 등). 성공 여부를 돌려준다.
    static func deleteDevice(_ udid: String) -> Bool {
        ShellRunner.runXcrun(["simctl", "delete", udid]).succeeded
    }

    static func eraseDevice(_ udid: String) -> Bool {
        ShellRunner.runXcrun(["simctl", "erase", udid]).succeeded
    }

    /// 부팅된 기기를 모두 종료한다. 기기·앱의 영구 데이터는 남지만 실행 중인 앱의
    /// 미저장 상태와 진행 중인 테스트/빌드는 끊긴다. 반드시 확인을 받은 뒤 호출한다.
    static func shutdownAll() -> Bool {
        ShellRunner.runXcrun(["simctl", "shutdown", "all"]).succeeded
    }
}
