import Foundation

/// `simctl runtime list -j`의 레코드 하나. 필드가 Xcode 버전에 따라 빠질 수 있어
/// identifier 외에는 전부 옵셔널로 받는다.
private struct SimctlRuntime: Decodable {
    let identifier: String
    let build: String?
    let version: String?
    let state: String?
    let deletable: Bool?
    let sizeBytes: Int64?
    let runtimeIdentifier: String?
    let lastUsedAt: Date?
}

/// 설치된 시뮬레이터 런타임 디스크 이미지 하나.
struct RuntimeItem: Identifiable, Hashable {
    let id: String // 디스크 이미지 UUID — `simctl runtime delete`가 받는 값
    let platform: String // "iOS"
    let version: String // "26.5"
    let build: String
    let state: String
    let deletable: Bool
    let sizeBytes: Int64
    let lastUsed: Date?
    /// 같은 플랫폼에 더 새 버전이 설치되어 있으면 true. 삭제 우선순위 힌트다.
    var isSuperseded: Bool = false

    var displayName: String { "\(platform) \(version) (\(build))" }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum RuntimeManager {
    static func listRuntimes() -> [RuntimeItem] {
        let result = ShellRunner.runXcrun(["simctl", "runtime", "list", "-j"])
        guard result.succeeded, let data = result.output.data(using: .utf8) else { return [] }
        return markSuperseded(parseRuntimes(data))
    }

    static func parseRuntimes(_ data: Data) -> [RuntimeItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([String: SimctlRuntime].self, from: data) else {
            return []
        }
        return records.values
            .map { record in
                // "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"의 첫 단어.
                let readable = SimulatorManager.shortRuntimeName(record.runtimeIdentifier ?? "")
                return RuntimeItem(
                    id: record.identifier,
                    platform: readable.split(separator: " ").first.map(String.init) ?? "?",
                    version: record.version ?? "?",
                    build: record.build ?? "?",
                    state: record.state ?? "?",
                    deletable: record.deletable ?? false,
                    sizeBytes: record.sizeBytes ?? 0,
                    lastUsed: record.lastUsedAt
                )
            }
            .sorted {
                if $0.platform != $1.platform { return $0.platform < $1.platform }
                // 새 버전이 위 — 남길 것이 먼저 보이고 구버전이 그 아래 붙는다.
                return $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }
    }

    /// 플랫폼별 최신 버전만 남기고 나머지에 구버전 표시를 단다.
    /// "26.3.1" vs "26.5" 같은 자릿수 다른 비교라 숫자 비교 옵션을 쓴다.
    static func markSuperseded(_ items: [RuntimeItem]) -> [RuntimeItem] {
        let newestByPlatform = Dictionary(grouping: items, by: \.platform).mapValues { group in
            group.map(\.version).max { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        return items.map { item in
            var item = item
            item.isSuperseded = newestByPlatform[item.platform].flatMap { $0 } != item.version
            return item
        }
    }

    /// 런타임 삭제는 즉시 끝나지 않는다 — simctl이 "Deleting" 상태로 두고 백그라운드에서
    /// 지운다. 성공 반환 후에도 목록에 한동안 남아 보이는 것이 정상이다.
    static func deleteRuntime(_ identifier: String) -> Bool {
        ShellRunner.runXcrun(["simctl", "runtime", "delete", identifier]).succeeded
    }
}
