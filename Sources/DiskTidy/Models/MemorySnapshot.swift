import Foundation

/// 메모리 압박 단계. `kern.memorystatus_vm_pressure_level`의 값이 그대로 온다.
/// 알 수 없는 값을 정상으로 접으면 압박 상태가 녹색으로 보인다. 원래 값을 보존한다.
enum MemoryPressureLevel: Equatable {
    case normal
    case warning
    case critical
    case unknown(Int32)

    init(rawLevel: Int32) {
        switch rawLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown(rawLevel)
        }
    }

    var label: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "경고"
        case .critical: return "위험"
        case .unknown(let value): return "알 수 없음 (\(value))"
        }
    }

    /// 데몬 정리 섹션을 강조할지 판단한다. 알 수 없는 값은 강조하지 않는다.
    var needsAttention: Bool {
        self == .warning || self == .critical
    }
}

/// `host_statistics64` 한 번에서 만든 물리 메모리 스냅샷.
/// Activity Monitor 항목과 근사 대응하며 정확한 풋프린트가 아니다.
struct MemorySnapshot: Equatable {
    let totalBytes: Int64
    let appBytes: Int64
    let wiredBytes: Int64
    let compressedBytes: Int64
    let cachedBytes: Int64
    let freeBytes: Int64
    let pressure: MemoryPressureLevel

    var freeFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(freeBytes) / Double(totalBytes)
    }
}

/// `vm.swapusage` 스냅샷. 읽기 전용 관측값이며 회수 가능 용량이 아니다.
struct SwapSnapshot: Equatable {
    let totalBytes: Int64
    let usedBytes: Int64
    let availableBytes: Int64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}
