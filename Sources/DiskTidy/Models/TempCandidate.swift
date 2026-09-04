import Darwin
import Foundation

/// `lstat`이 주는 나노초 해상도 시각. `Date`로 옮기면 반올림 때문에
/// 삭제 직전 동일성 확인에서 같은 파일이 다른 파일로 보인다.
struct FileTimestamp: Hashable, Codable {
    let seconds: Int64
    let nanoseconds: Int64

    init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(_ spec: timespec) {
        self.init(seconds: Int64(spec.tv_sec), nanoseconds: Int64(spec.tv_nsec))
    }

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}

/// 스캔 시점의 파일 동일성. 경로 문자열만으로 삭제 대상을 다시 찾으면
/// 스캔과 삭제 사이에 이름이 바뀐 다른 파일을 지운다.
struct FileIdentity: Hashable, Codable {
    let device: UInt64
    let inode: UInt64
    let ownerUID: UInt32
    let mode: UInt32
    let modifiedAt: FileTimestamp
    let accessedAt: FileTimestamp

    init(
        device: UInt64,
        inode: UInt64,
        ownerUID: UInt32,
        mode: UInt32,
        modifiedAt: FileTimestamp,
        accessedAt: FileTimestamp
    ) {
        self.device = device
        self.inode = inode
        self.ownerUID = ownerUID
        self.mode = mode
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
    }

    init(_ status: stat) {
        self.init(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: status.st_ino,
            ownerUID: status.st_uid,
            mode: UInt32(status.st_mode),
            modifiedAt: FileTimestamp(status.st_mtimespec),
            accessedAt: FileTimestamp(status.st_atimespec)
        )
    }

    /// 사용 중 강제 삭제는 쓰기·읽기로 바뀌는 시각만 허용한다.
    /// 경로가 다른 객체로 교체됐는지는 device와 inode를 포함한 나머지 필드로 계속 막는다.
    func matches(_ status: stat, ignoringActivity: Bool) -> Bool {
        let current = FileIdentity(status)
        guard ignoringActivity else { return self == current }
        return device == current.device
            && inode == current.inode
            && ownerUID == current.ownerUID
            && mode == current.mode
    }

}

/// 완전 삭제 대상. `CleanableItem`은 표시와 휴지통 이동만 표현하고 동일성을
/// 보존하지 않으므로 되돌릴 수 없는 삭제에는 쓰지 않는다.
struct TempCandidate: Identifiable, Hashable {
    /// 구분 문자를 직렬화하지 않아 `:`가 든 합법 경로도 충돌하지 않는다.
    struct ID: Hashable {
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
    }

    let name: String
    let path: URL
    let canonicalPath: String
    let sizeBytes: Int64
    let modifiedDate: Date
    let identity: FileIdentity
    var isSelected = false
    /// 출처. 판정 규칙과 화면 그룹이 여기서 갈린다 — `AgentWorkspace` 참고.
    var kind: TempCandidateKind = .other
    /// 후보로 올라온 근거, 또는 사용 중 경고. 화면에 한 줄로 보인다.
    var evidence: String = ""
    /// 사용 중 경고가 필요한 행. 사용자가 확인하면 강제 삭제할 수 있다.
    var isInUse = false

    var id: ID {
        ID(canonicalPath: canonicalPath, device: identity.device, inode: identity.inode)
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// 행마다 새로 만들면 688개 목록에서 체크박스 하나만 눌러도 보이는 행 전부가 재생성한다.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var modifiedDateString: String { Self.dayFormatter.string(from: modifiedDate) }

    /// 임시파일 탭은 분 단위(30분 정지)로 판정하므로 날짜만으로는 "왜 지금 후보인지/아닌지"가 안 읽힌다.
    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var modifiedTimeString: String { Self.minuteFormatter.string(from: modifiedDate) }
}
