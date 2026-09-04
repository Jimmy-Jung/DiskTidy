import Darwin
import Foundation
import os

/// 격리 이동 중 앱이 죽어도 항목이 고아로 남지 않도록 이동 전후 상태를 파일로 남긴다.
/// 레코드마다 파일 하나라 읽기-수정-쓰기 경합이 없고, 완료는 파일 삭제로 표현한다.
private struct JournalRecord: Codable {
    enum State: String, Codable {
        case prepared
        case staged
    }

    let id: UUID
    /// 루트 기준 상대 경로. 루트 바로 아래면 빈 문자열.
    let sourceParentRelative: String
    let sourceName: String
    let identity: FileIdentity
    /// 이전 버전 레코드에는 키가 없으므로 optional로 두고 false로 해석한다.
    let ignoringActivity: Bool?
    /// 복구 로직은 stage 파일의 존재 여부로 판단하므로 이 값을 읽지 않는다.
    /// 어디까지 진행됐는지 사후에 알기 위해 durable하게 남긴다 (설계 문서 4절 요구사항).
    var state: State
}

private enum JournalEntry {
    case valid(JournalRecord)
    /// 디코딩할 수 없는 레코드. 자동 삭제하지 않고 복구 화면에만 올린다.
    case damaged
}

/// 루트 하나당 격리 디렉터리와 durable journal 한 벌.
private struct QuarantineJournal {
    let rootPath: String
    let quarantineURL: URL
    let recordsURL: URL

    /// 격리 디렉터리는 0700으로만 쓴다. 이미 있는데 우리 소유가 아니거나 권한이 더
    /// 열려 있으면 다른 프로세스가 stage 항목을 갈아치울 수 있으므로 쓰지 않는다.
    init?(rootPath: String, creatingIfMissing: Bool) {
        self.rootPath = rootPath
        quarantineURL = URL(
            fileURLWithPath: rootPath + "/" + TempScanner.quarantineDirectoryName
        )
        recordsURL = quarantineURL.appendingPathComponent("journal")

        guard Self.isUsableDirectory(quarantineURL.path, creating: creatingIfMissing),
              Self.isUsableDirectory(recordsURL.path, creating: creatingIfMissing) else {
            return nil
        }
    }

    /// 이 함수의 두 방어는 변이 검사로 확인해 보니 테스트가 잡지 못한다. 이유를 남긴다.
    /// - `st_uid == getuid()`: 타 UID 소유 디렉터리를 만들려면 root 권한이 필요하다.
    /// - `fchmodat(AT_SYMLINK_NOFOLLOW)`: 심볼릭 링크가 **미리** 있으면 아래 `lstat`이
    ///   성공해 `S_IFLNK`로 걸러지므로 chmod 분기에 도달하지 않는다. `chmod`와의 차이는
    ///   `lstat` 실패 직후 링크가 끼어드는 경합에서만 드러나고, 그 창을 벌리려면
    ///   이 private 함수 안에 테스트 전용 훅을 넣어야 한다. 방어는 유지하되 미검증으로 둔다.
    private static func isUsableDirectory(_ path: String, creating: Bool) -> Bool {
        var status = stat()
        if lstat(path, &status) != 0 {
            // lstat과 mkdir 사이에 다른 인스턴스가 먼저 만들 수 있다. EEXIST는 성공으로 본다.
            // 아래 소유자·권한 확인이 남아 있으므로 남의 디렉터리를 그냥 쓰지는 않는다.
            guard creating, mkdir(path, 0o700) == 0 || errno == EEXIST else { return false }
            // mkdir 모드는 umask에 깎인다. 정확히 0700으로 되돌린다.
            // `chmod`는 심볼릭 링크를 따라간다. `/private/tmp`은 1777이라 타 UID가 그 틈에
            // 링크를 끼워 넣으면 우리 소유 임의 디렉터리의 모드가 바뀐다(실측). 링크는 따라가지 않는다.
            guard fchmodat(AT_FDCWD, path, 0o700, AT_SYMLINK_NOFOLLOW) == 0,
                  lstat(path, &status) == 0 else { return false }
        }
        return status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == getuid()
            && status.st_mode & 0o777 == 0o700
    }

    // MARK: 경로

    func stageURL(_ id: UUID) -> URL {
        quarantineURL.appendingPathComponent(id.uuidString)
    }

    /// journal은 디스크의 파일이다. 손상되거나 조작된 레코드가 루트 밖을 가리키면
    /// 복원이 임의 경로 쓰기가 된다. 경계 검사는 여기서 한 번에 한다.
    func sourceParentPath(of record: JournalRecord) -> String? {
        guard !record.sourceName.isEmpty,
              !record.sourceName.contains("/"),
              record.sourceName != ".", record.sourceName != ".." else { return nil }

        let relative = record.sourceParentRelative
        guard !relative.hasPrefix("/") else { return nil }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }

        let parent = components.isEmpty
            ? rootPath
            : rootPath + "/" + components.joined(separator: "/")
        guard parent == rootPath || CanonicalPath.contains(rootPath, parent) else { return nil }
        return parent
    }

    func originalPath(of record: JournalRecord) -> String? {
        sourceParentPath(of: record).map { $0 + "/" + record.sourceName }
    }

    /// 삭제 대상의 부모 경로를 루트 기준 상대 경로로 바꾼다.
    func relativeParent(of parentPath: String) -> String? {
        if parentPath == rootPath { return "" }
        guard CanonicalPath.contains(rootPath, parentPath) else { return nil }
        return String(parentPath.dropFirst(rootPath.count + 1))
    }

    // MARK: 레코드

    func entries() -> [(id: UUID, entry: JournalEntry)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: recordsURL.path)
        else { return [] }

        return names.compactMap { name in
            guard name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))) else { return nil }
            return (id, decode(id))
        }
    }

    func entry(_ id: UUID) -> JournalEntry? {
        guard FileManager.default.fileExists(atPath: recordURL(id).path) else { return nil }
        return decode(id)
    }

    /// journal에 대응 레코드가 없는 stage 항목(고아). 자동 삭제하지 않는다.
    func orphanStageIDs() -> [UUID] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: quarantineURL.path)
        else { return [] }

        let recorded = Set(entries().map(\.id))
        return names.compactMap(UUID.init(uuidString:)).filter { !recorded.contains($0) }
    }

    @discardableResult
    func write(_ record: JournalRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return writeDurably(data, to: recordURL(record.id)) && fsyncDirectory(recordsURL)
    }

    func remove(_ id: UUID) {
        unlink(recordURL(id).path)
        _ = fsyncDirectory(recordsURL)
    }

    private func recordURL(_ id: UUID) -> URL {
        recordsURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func decode(_ id: UUID) -> JournalEntry {
        guard let data = try? Data(contentsOf: recordURL(id)),
              let record = try? JSONDecoder().decode(JournalRecord.self, from: data),
              record.id == id else { return .damaged }
        return .valid(record)
    }

    // MARK: durable 쓰기

    /// 이동 전 준비 레코드가 디스크에 닿아 있어야 앱이 죽어도 stage를 되찾을 수 있다.
    ///
    /// 살아 있는 레코드를 `O_TRUNC`로 제자리에서 잘라내면, 전원 손실이나 쓰기 오류가
    /// 그 사이에 끼었을 때 0바이트 레코드가 남아 원본 경로를 영영 잃는다.
    /// 임시 파일에 다 쓰고 `rename`으로 갈아 끼운다 — 실패해도 기존 레코드는 그대로다.
    private func writeDurably(_ data: Data, to url: URL) -> Bool {
        let temporaryURL = recordsURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }

        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                // 이 타입의 `write(_ record:)`와 이름이 겹친다. 전역 쪽을 명시한다.
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }

        guard written, flushToMedia(descriptor) else {
            close(descriptor)
            unlink(temporaryURL.path)
            return false
        }
        close(descriptor)

        guard rename(temporaryURL.path, url.path) == 0 else {
            unlink(temporaryURL.path)
            return false
        }
        return true
    }

    private func fsyncDirectory(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flushToMedia(descriptor)
    }

    /// macOS의 `fsync(2)`는 드라이브 캐시까지만 밀어내고 매체 커밋은 보장하지 않는다.
    /// 이 journal이 대비하는 유일한 시나리오가 갑작스러운 전원 손실이므로 `F_FULLFSYNC`를 쓴다.
    private func flushToMedia(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) != -1
    }
}

/// 되돌릴 수 없는 완전 삭제. 호출 전 반드시 사용자 확인을 거친다.
///
/// 일반 루트에서 바로 `unlinkat`하지 않는다. 삭제 직전 identity를 다시 확인하고
/// 같은 볼륨의 격리 디렉터리로 `renameatx_np(RENAME_EXCL)` 원자 이동한 뒤,
/// 격리 위치의 identity가 그대로일 때만 지운다. 마지막 component가 바뀌어도
/// 다른 항목을 삭제하지 않기 위한 절차다.
///
/// 위협 모델에 **같은 UID의 적대 프로세스는 포함하지 않는다**. macOS에는 inode를
/// 조건으로 하는 unlink API가 없고, 격리 디렉터리도 같은 UID면 조작할 수 있다.
enum PermanentDeleter {
    private static let logger = Logger(subsystem: "com.jimmy.disktidy", category: "temp-delete")

    /// stage 이름 충돌 재시도 횟수. UUID 충돌은 실질적으로 일어나지 않지만,
    /// 남의 손이 낀 경우 무한 재시도로 돌지 않게 상한을 둔다.
    private static let stageNameAttempts = 5

    enum Outcome: Equatable {
        case deleted
        case refused(Refusal)
        case failed(Int32)
    }

    enum Refusal: Equatable {
        case outsideProductionRoot
        case identityChanged
        case inUse
        case unsafeTree
        case quarantineUnavailable
        case quarantineRecoveryRequired
    }

    enum RestoreOutcome: Equatable {
        case restored
        case refused(Refusal)
        case failed(Int32)
    }

    struct QuarantineRecovery: Identifiable, Hashable {
        let id: UUID
        /// 원본 경로를 알 수 없는 손상·고아 항목은 빈 문자열.
        let originalPath: String
        let quarantinedPath: URL
    }

    /// 격리 이동 구간의 경합을 테스트에서 결정적으로 재현하기 위한 훅.
    /// 기본값이 곧 production 동작이며, 호출부는 `delete(_:)`만 쓴다.
    struct StageHooks {
        var nextStageID: @Sendable () -> UUID = { UUID() }
        /// 격리 이동이 끝난 직후, identity 재확인 **전에** 불린다.
        var afterStage: @Sendable (URL) -> Void = { _ in }

        static let production = StageHooks()
    }

    // MARK: - 삭제

    /// 되돌릴 수 없다. 반드시 사용자 확인 뒤에만 호출한다.
    static func delete(_ candidate: TempCandidate) -> Outcome {
        delete(candidate, allowInUse: false, hooks: .production)
    }

    /// 스캔에서 사용 중 경고가 표시된 항목만 활동 검사를 건너뛴다.
    /// 루트·소유권·종류·identity·마운트·격리 검증은 그대로 적용한다.
    static func delete(_ candidate: TempCandidate, allowInUse: Bool) -> Outcome {
        delete(candidate, allowInUse: allowInUse, hooks: .production)
    }

    static func delete(_ candidate: TempCandidate, hooks: StageHooks) -> Outcome {
        delete(candidate, allowInUse: false, hooks: hooks)
    }

    static func delete(
        _ candidate: TempCandidate, allowInUse: Bool, hooks: StageHooks
    ) -> Outcome {
        let policy = TempRootPolicy.production
        // `/tmp` 표기를 그대로 두면 루트 밖으로 오판하고, 부모 `/tmp`이 심볼릭 링크라
        // `O_NOFOLLOW` 열기도 ELOOP로 실패한다. 표기만 맞춘다 —
        // 최종 대상에 `resolvingSymlinksInPath()`를 걸어 링크를 따라가는 것과 다르다.
        let path = CanonicalPath.normalizingPrefix(candidate.canonicalPath)

        guard !policy.isRoot(path), let root = policy.root(containing: path) else {
            return .refused(.outsideProductionRoot)
        }
        // 격리 디렉터리를 후보로 삼으면 복구 대기 항목을 지운다.
        let quarantineRoot = root + "/" + TempScanner.quarantineDirectoryName
        guard path != quarantineRoot, !CanonicalPath.contains(quarantineRoot, path) else {
            return .refused(.outsideProductionRoot)
        }
        // 경고 행을 본 사용자가 확인한 경우에만 활동성 메타데이터 변화를 허용한다.
        guard !candidate.isInUse || allowInUse else { return .refused(.inUse) }
        let ignoringActivity = candidate.isInUse && allowInUse

        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !parentPath.isEmpty else { return .refused(.outsideProductionRoot) }

        // 상위 경로 교체와 링크 추적을 막는다. 이후 모든 확인은 이 FD 기준이다.
        let parentDescriptor = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { return .failed(errno) }
        defer { close(parentDescriptor) }

        // 스캔 결과의 URL을 곧바로 removeItem에 넘기면 그 사이 바뀐 다른 파일을 지운다.
        var current = stat()
        guard fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            // `/tmp`은 macOS 주기 작업이 상시 정리한다. 이미 없으면 목표 상태는 달성된 것이므로
            // 오류로 세지 않는다. 오류로 두면 목록에 남아 누를 때마다 errno 2가 반복된다.
            return code == ENOENT ? .deleted : .failed(code)
        }
        guard candidate.identity.matches(current, ignoringActivity: ignoringActivity) else {
            return .refused(.identityChanged)
        }

        // 마운트 포인트를 품은 디렉터리는 rename이 성공한다(실측). 부모와 device가 다르면
        // 그 자체가 마운트 루트이므로 건드리지 않는다.
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0 else { return .failed(errno) }
        guard current.st_dev == parentStatus.st_dev else { return .refused(.unsafeTree) }

        // 일반 후보가 스캔 뒤 새로 사용되기 시작한 경우는 계속 fail-closed로 거부한다.
        let openPaths: Set<String>
        if ignoringActivity {
            openPaths = []
        } else {
            // lsof 실패는 "열려 있지 않다"가 아니라 "알 수 없다"다. fail-closed로 거부한다.
            guard let paths = try? TempScanner.relevantOpenPaths(policy: policy) else {
                return .refused(.inUse)
            }
            openPaths = paths
        }
        let now = Date()

        // 일반 후보는 스캔과 삭제 사이에 세션이 재개되거나 빌드가 다시 돌면 거부한다.
        if !ignoringActivity,
           AgentWorkspace.blockingReason(for: candidate.kind, path: path, live: .current()) != nil {
            return .refused(.inUse)
        }

        switch TempScanner.decide(
            stat: current, path: path, rootPaths: policy.rootSet,
            openPaths: openPaths, now: now, ageRule: candidate.kind.ageRule,
            ignoringActivity: ignoringActivity
        ) {
        case .eligible: break
        case .inUse: return .refused(.inUse)
        case .isRoot: return .refused(.outsideProductionRoot)
        default: return .refused(.unsafeTree)
        }

        if current.st_mode & S_IFMT == S_IFDIR,
           !TempScanner.isTreeSafe(
               at: path, device: current.st_dev, openPaths: openPaths, now: now,
               ageRule: candidate.kind.ageRule, ignoringActivity: ignoringActivity
           ) {
            return .refused(.unsafeTree)
        }

        guard let journal = QuarantineJournal(rootPath: root, creatingIfMissing: true),
              let relativeParent = journal.relativeParent(of: parentPath) else {
            return .refused(.quarantineUnavailable)
        }
        let quarantineDescriptor = open(
            journal.quarantineURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard quarantineDescriptor >= 0 else { return .refused(.quarantineUnavailable) }
        defer { close(quarantineDescriptor) }

        var lastErrno: Int32 = EEXIST
        for _ in 0 ..< stageNameAttempts {
            let record = JournalRecord(
                id: hooks.nextStageID(),
                sourceParentRelative: relativeParent,
                sourceName: name,
                identity: candidate.identity,
                ignoringActivity: ignoringActivity ? true : nil,
                state: .prepared
            )
            guard journal.write(record) else { return .refused(.quarantineUnavailable) }

            // plain renameat은 목적지를 덮어쓴다. RENAME_EXCL만 쓴다.
            guard renameatx_np(
                parentDescriptor, name,
                quarantineDescriptor, record.id.uuidString,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                lastErrno = errno
                journal.remove(record.id)
                // EXDEV에 복사/삭제 fallback을 두지 않는다. 볼륨을 넘는 이동은 원자적이지 않다.
                guard lastErrno == EEXIST else { return .failed(lastErrno) }
                continue
            }

            // 여기부터 identity 재확인까지가 마지막 이름이 바뀔 수 있는 구간이다.
            hooks.afterStage(journal.stageURL(record.id))

            return completeDelete(
                record: record, journal: journal,
                quarantineDescriptor: quarantineDescriptor,
                parentDescriptor: parentDescriptor,
                candidate: candidate, now: now, ignoringActivity: ignoringActivity
            )
        }
        return .failed(lastErrno)
    }

    /// 격리 위치에서 identity를 다시 확인하고, 같을 때만 격리 FD 아래에서 지운다.
    private static func completeDelete(
        record: JournalRecord,
        journal: QuarantineJournal,
        quarantineDescriptor: Int32,
        parentDescriptor: Int32,
        candidate: TempCandidate,
        now: Date,
        ignoringActivity: Bool
    ) -> Outcome {
        let stageName = record.id.uuidString

        var stagedStatus = stat()
        guard fstatat(quarantineDescriptor, stageName, &stagedStatus, AT_SYMLINK_NOFOLLOW) == 0
        else {
            journal.write(marked(record, as: .staged))
            return .refused(.quarantineRecoveryRequired)
        }

        guard candidate.identity.matches(stagedStatus, ignoringActivity: ignoringActivity) else {
            // 검증 뒤 마지막 이름이 바뀐 경우. 새 항목은 절대 지우지 않고 되돌린다.
            return restoreStage(
                record: record, journal: journal,
                quarantineDescriptor: quarantineDescriptor,
                parentDescriptor: parentDescriptor,
                onSuccess: .identityChanged
            )
        }

        guard journal.write(marked(record, as: .staged)) else {
            return .refused(.quarantineRecoveryRequired)
        }

        let stagePath = journal.stageURL(record.id).path
        if stagedStatus.st_mode & S_IFMT == S_IFDIR {
            // 이동 전 스냅샷의 경로는 `<root>/<name>/…`이고 재검증 대상은
            // `<root>/.DiskTidyQuarantine/<uuid>/…`다. 그대로 쓰면 접두사가 영영 일치하지 않아
            // 마지막 관문에서 규칙 4가 죽는다. 격리 경로 기준으로 다시 찍는다.
            let stagedOpenPaths: Set<String>
            if ignoringActivity {
                // 열린 일반 파일은 unlink할 수 있지만 열린 디렉터리 FD/cwd는 rename 뒤에도
                // 자식을 만들 수 있다. 마지막 트리 검증을 무효화하므로 원위치로 복원한다.
                guard let paths = try? TempScanner.relevantOpenPaths(
                    policy: TempRootPolicy.production
                ), let hasOpenDirectory = hasOpenDirectory(atOrBelow: stagePath, in: paths),
                      !hasOpenDirectory else {
                    return restoreStage(
                        record: record, journal: journal,
                        quarantineDescriptor: quarantineDescriptor,
                        parentDescriptor: parentDescriptor,
                        onSuccess: .inUse
                    )
                }
                stagedOpenPaths = []
            } else {
                guard let paths = try? TempScanner.relevantOpenPaths(
                    policy: TempRootPolicy.production
                ) else {
                    return restoreStage(
                        record: record, journal: journal,
                        quarantineDescriptor: quarantineDescriptor,
                        parentDescriptor: parentDescriptor,
                        onSuccess: .inUse
                    )
                }
                stagedOpenPaths = paths
            }
            if !TempScanner.isTreeSafe(
                at: stagePath, device: stagedStatus.st_dev, openPaths: stagedOpenPaths,
                now: now, ageRule: candidate.kind.ageRule,
                ignoringActivity: ignoringActivity
            ) {
                return restoreStage(
                    record: record, journal: journal,
                    quarantineDescriptor: quarantineDescriptor,
                    parentDescriptor: parentDescriptor,
                    onSuccess: .unsafeTree
                )
            }
        }

        do {
            try FileManager.default.removeItem(atPath: stagePath)
        } catch {
            logger.error(
                """
                격리 항목 삭제 실패 \(stagePath, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            // 원본에서는 이미 격리로 이동했다. 일반 실패로 돌리면 후보 목록에도 남아
            // 복구 목록과 중복되므로, journal을 보존한 채 복구 대상으로만 올린다.
            return .refused(.quarantineRecoveryRequired)
        }

        // 성공 삭제 뒤에만 journal을 완료 상태(= 레코드 제거)로 만든다.
        journal.remove(record.id)
        return .deleted
    }

    /// 열린 디렉터리는 stage rename 뒤에도 기존 FD를 통해 자식을 만들 수 있다.
    /// 경로가 사라져 타입을 확인할 수 없는 경우도 안전을 증명할 수 없으므로 nil이다.
    private static func hasOpenDirectory(
        atOrBelow root: String, in openPaths: Set<String>
    ) -> Bool? {
        for path in openPaths
        where path == root || CanonicalPath.contains(root, path) {
            var status = stat()
            guard lstat(path, &status) == 0 else { return nil }
            if status.st_mode & S_IFMT == S_IFDIR { return true }
        }
        return false
    }

    /// 격리에서 원래 자리로 되돌린다. 되돌리지 못하면 항목을 보존한 채 복구를 요구한다.
    private static func restoreStage(
        record: JournalRecord,
        journal: QuarantineJournal,
        quarantineDescriptor: Int32,
        parentDescriptor: Int32,
        onSuccess refusal: Refusal
    ) -> Outcome {
        // 원래 이름이 이미 채워졌으면 EEXIST로 덮어쓰기를 막고 격리 항목을 남긴다.
        guard renameatx_np(
            quarantineDescriptor, record.id.uuidString,
            parentDescriptor, record.sourceName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            journal.write(marked(record, as: .staged))
            return .refused(.quarantineRecoveryRequired)
        }
        journal.remove(record.id)
        return .refused(refusal)
    }

    private static func marked(
        _ record: JournalRecord, as state: JournalRecord.State
    ) -> JournalRecord {
        var updated = record
        updated.state = state
        return updated
    }

    // MARK: - 복구

    /// 앱 시작 시 일반 스캔보다 먼저 읽는다. 준비·staged·손상·고아 항목을 모두 보여 주고
    /// 어느 것도 자동으로 지우지 않는다.
    static func pendingRecoveries() -> [QuarantineRecovery] {
        var recoveries: [QuarantineRecovery] = []
        for root in TempRootPolicy.production.roots {
            guard let journal = QuarantineJournal(rootPath: root, creatingIfMissing: false) else {
                continue
            }

            for (id, entry) in journal.entries() {
                let originalPath: String
                switch entry {
                case .valid(let record): originalPath = journal.originalPath(of: record) ?? ""
                case .damaged: originalPath = ""
                }
                recoveries.append(
                    QuarantineRecovery(
                        id: id, originalPath: originalPath, quarantinedPath: journal.stageURL(id)
                    )
                )
            }

            for id in journal.orphanStageIDs() {
                recoveries.append(
                    QuarantineRecovery(
                        id: id, originalPath: "", quarantinedPath: journal.stageURL(id)
                    )
                )
            }
        }
        return recoveries.sorted {
            ($0.originalPath, $0.id.uuidString) < ($1.originalPath, $1.id.uuidString)
        }
    }

    /// journal ID로만 복원한다. 임의 source/destination path는 받지 않는다.
    static func restore(_ recoveryID: UUID) -> RestoreOutcome {
        for root in TempRootPolicy.production.roots {
            guard let journal = QuarantineJournal(rootPath: root, creatingIfMissing: false),
                  let entry = journal.entry(recoveryID) else { continue }
            guard case .valid(let record) = entry else {
                return .refused(.quarantineRecoveryRequired)
            }
            return restore(record, journal: journal)
        }
        // 고아 stage에는 되돌릴 원본 경로가 없다. Finder에서 직접 옮기는 수밖에 없다.
        return .refused(.quarantineRecoveryRequired)
    }

    private static func restore(
        _ record: JournalRecord, journal: QuarantineJournal
    ) -> RestoreOutcome {
        guard let parentPath = journal.sourceParentPath(of: record) else {
            return .refused(.quarantineRecoveryRequired)
        }

        let quarantineDescriptor = open(
            journal.quarantineURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard quarantineDescriptor >= 0 else { return .refused(.quarantineUnavailable) }
        defer { close(quarantineDescriptor) }

        let stageName = record.id.uuidString
        var stagedStatus = stat()
        guard fstatat(quarantineDescriptor, stageName, &stagedStatus, AT_SYMLINK_NOFOLLOW) == 0
        else {
            // stage가 없다 = 이 레코드로 격리된 것이 없다. 이동 전에 앱이 죽었거나,
            // 삭제까지 끝내고 journal 정리만 못 했거나 둘 중 하나다. 어느 쪽이든 레코드는
            // 장부일 뿐이라 지워도 파일이 사라지지 않는다. 조건을 달면 복원도 삭제도 안 되는
            // 행이 영구히 남는다 — 사용자가 JSON을 직접 지우기 전까지.
            journal.remove(record.id)
            return .restored
        }
        // 복원 직전에도 stage identity를 journal과 대조한다.
        guard record.identity.matches(
            stagedStatus, ignoringActivity: record.ignoringActivity == true
        ) else {
            return .refused(.identityChanged)
        }

        let parentDescriptor = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { return .refused(.quarantineRecoveryRequired) }
        defer { close(parentDescriptor) }

        guard renameatx_np(
            quarantineDescriptor, stageName,
            parentDescriptor, record.sourceName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            // 원래 이름이 다시 채워졌다. 덮어쓰지 않고 격리 항목을 그대로 보존한다.
            return code == EEXIST ? .refused(.quarantineRecoveryRequired) : .failed(code)
        }

        journal.remove(record.id)
        return .restored
    }

}
