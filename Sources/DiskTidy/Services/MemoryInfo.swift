import Darwin
import Foundation

/// 메모리·스왑 지표를 셸 없이 Darwin API로 읽는다.
///
/// 각 지표는 독립적으로 실패할 수 있다. 실패를 0으로 바꾸면 "메모리 압박 없음"이나
/// "스왑 없음"으로 보이므로, 실패는 그대로 `Error`로 돌려 UI가 "측정 불가"를 그리게 한다.
///
/// 스왑은 **읽기 전용 관측값**이다. `purge`도, 스왑 파일 조작도 하지 않는다.
enum MemoryInfo {
    enum Error: Swift.Error, Equatable {
        case hostStatistics(kern_return_t)
        case swapUsage(Int32)
        case vmDirectory(Int32)
    }

    /// 스왑 파일이 사는 별도 APFS 볼륨. 열거만 하고 절대 쓰지 않는다.
    static let vmVolumePath = "/System/Volumes/VM"

    /// 이 값을 넘으면 안내 배너를 띄운다. 회수 가능 용량이 아니라 현재 할당량 기준이다.
    static let swapFileNoticeThreshold: Int64 = 8 * 1024 * 1024 * 1024

    // MARK: - 물리 메모리

    static func memory() -> Result<MemorySnapshot, Error> {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .failure(.hostStatistics(result)) }

        let pageSize = Int64(vm_kernel_page_size)
        func bytes(_ pages: natural_t) -> Int64 { Int64(pages) * pageSize }

        // 앱 메모리에서 purgeable을 빼고 캐시된 파일에 더한다 (Activity Monitor 대응, 근사).
        let purgeable = bytes(stats.purgeable_count)
        return .success(
            MemorySnapshot(
                totalBytes: totalPhysicalBytes(),
                appBytes: max(0, bytes(stats.internal_page_count) - purgeable),
                wiredBytes: bytes(stats.wire_count),
                compressedBytes: bytes(stats.compressor_page_count),
                cachedBytes: bytes(stats.external_page_count) + purgeable,
                freeBytes: bytes(stats.free_count) + bytes(stats.speculative_count),
                pressure: pressureLevel()
            )
        )
    }

    private static func totalPhysicalBytes() -> Int64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 else { return 0 }
        return Int64(bitPattern: total)
    }

    private static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return .unknown(-1) }
        return MemoryPressureLevel(rawLevel: level)
    }

    // MARK: - 스왑

    static func swap() -> Result<SwapSnapshot, Error> {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            let code = errno
            // 구조체 조회가 막힌 대상에서만 문자열 표기로 물러난다.
            // 여기서도 실패하면 0이 아니라 오류다 — 0은 "스왑 없음"으로 읽힌다.
            guard let parsed = parseSwapUsage(
                ShellRunner.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).output
            ) else { return .failure(.swapUsage(code)) }
            return .success(parsed)
        }
        return .success(
            SwapSnapshot(
                totalBytes: Int64(bitPattern: usage.xsu_total),
                usedBytes: Int64(bitPattern: usage.xsu_used),
                availableBytes: Int64(bitPattern: usage.xsu_avail)
            )
        )
    }

    /// `total = 40960.00M  used = 39653.88M  free = 1306.12M  (encrypted)` 형태를 읽는다.
    /// 세 값이 모두 있어야 성공이다. 일부만 읽히면 나머지를 0으로 채우지 않고 nil이다.
    static func parseSwapUsage(_ output: String) -> SwapSnapshot? {
        var values: [String: Int64] = [:]
        // `=` 기준으로 자르면 `total`, `40960.00M used`, … 순으로 떨어진다.
        let segments = output.split(separator: "=")
        for index in segments.indices.dropLast() {
            guard let key = segments[index].split(whereSeparator: \.isWhitespace).last,
                  let rawValue = segments[index + 1]
                      .split(whereSeparator: \.isWhitespace).first,
                  let bytes = parseSizeToken(String(rawValue)) else { continue }
            values[String(key)] = bytes
        }

        guard let total = values["total"],
              let used = values["used"],
              let free = values["free"] else { return nil }
        return SwapSnapshot(totalBytes: total, usedBytes: used, availableBytes: free)
    }

    /// `40960.00M` / `1.25G` / `512K` / `1024` → 바이트. 알 수 없는 접미사는 nil.
    private static func parseSizeToken(_ token: String) -> Int64? {
        let multipliers: [Character: Double] = [
            "K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024
        ]
        var numberPart = token
        var multiplier: Double = 1

        if let suffix = token.last, !suffix.isNumber {
            guard let factor = multipliers[Character(suffix.uppercased())] else { return nil }
            multiplier = factor
            numberPart = String(token.dropLast())
        }

        guard let number = Double(numberPart), number >= 0, number.isFinite else { return nil }
        let bytes = number * multiplier
        guard bytes <= Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    /// `/System/Volumes/VM`의 `swapfile*` 크기 합. **현재 할당 관측값**이며
    /// 사용자가 되찾을 수 있는 바이트 수가 아니다.
    static func swapFileBytes() -> Result<Int64, Error> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: vmVolumePath) else {
            // 열거 실패를 0으로 바꾸면 "스왑 없음"으로 보인다. 오류로 남긴다.
            return .failure(.vmDirectory(errno))
        }

        var total: Int64 = 0
        for name in names where name.hasPrefix("swapfile") {
            var status = stat()
            guard lstat(vmVolumePath + "/" + name, &status) == 0 else { continue }
            total += Int64(status.st_size)
        }
        return .success(total)
    }
}
