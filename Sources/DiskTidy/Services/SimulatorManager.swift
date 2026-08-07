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

enum SimulatorManager {
    static func listDevices() -> [SimulatorItem] {
        let result = ShellRunner.runXcrun(["simctl", "list", "devices", "-j"])
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimctlDeviceList.self, from: data) else {
            return []
        }

        let devicesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")

        // 런타임이 삭제된 고아 기기는 simctl이 isAvailable=false로 표시한다.
        // 실체가 없어 삭제도 안 되므로 목록에서 뺀다.
        let available = list.devices.flatMap { runtimeKey, devices in
            devices
                .filter { $0.isAvailable ?? true }
                .map { (runtime: shortRuntimeName(runtimeKey), device: $0) }
        }

        let deviceURLs = available.map { devicesRoot.appendingPathComponent($0.device.udid) }
        let sizes = DiskScanner.sizes(of: deviceURLs)

        return available
            .map { entry in
                let deviceURL = devicesRoot.appendingPathComponent(entry.device.udid)
                return SimulatorItem(
                    id: entry.device.udid,
                    name: entry.device.name,
                    runtime: entry.runtime,
                    state: entry.device.state,
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
}
