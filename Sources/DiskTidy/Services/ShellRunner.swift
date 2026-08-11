import Foundation

/// 외부 명령 실행 결과.
struct ShellResult {
    let output: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

/// 흘러오는 자식 프로세스 출력. 종료 코드는 마지막에 한 번 온다.
enum ShellStreamEvent: Equatable, Sendable {
    case line(String)
    case exit(Int32)
}

/// `streamLines`가 두 신호를 합치는 자리.
///
/// stdout EOF와 프로세스 종료는 순서가 정해져 있지 않다. 한쪽만 보고 끝내면 종료 코드를
/// 못 싣거나(EOF만 봄) 남은 출력을 버린다(종료만 봄).
///
/// 이 타입의 메서드는 `streamLines`가 만든 직렬 큐에서만 부른다 — 그래서 락이 없다.
/// `@unchecked Sendable`은 그 규칙에 기대는 것이고, 큐 밖에서 부르면 규칙이 깨진다.
/// 타임아웃 감시자도 여기서 들고 있는다. 클로저 여러 개가 각자 잡으면 그때부터
/// 진짜 경합이다.
private final class StreamState: @unchecked Sendable {
    private let continuation: AsyncStream<ShellStreamEvent>.Continuation
    private let watchdog: DispatchWorkItem?
    private var exitCode: Int32?
    private var hasOutputEnded = false
    private var hasFinished = false

    init(
        continuation: AsyncStream<ShellStreamEvent>.Continuation,
        watchdog: DispatchWorkItem?
    ) {
        self.continuation = continuation
        self.watchdog = watchdog
    }

    func cancelWatchdog() {
        watchdog?.cancel()
    }

    func processExited(code: Int32) {
        exitCode = code
        finishIfReady()
    }

    func outputEnded() {
        hasOutputEnded = true
        finishIfReady()
    }

    private func finishIfReady() {
        guard !hasFinished, hasOutputEnded, let exitCode else { return }
        hasFinished = true
        continuation.yield(.exit(exitCode))
        continuation.finish()
    }
}

enum ShellRunner {
    /// stdout을 줄 단위로 흘려 준다. `run(_:_:)`과 달리 종료를 기다리지 않는다.
    ///
    /// 스트리밍 응답에는 이쪽이 필요하다. `run(_:_:)`은 `readDataToEndOfFile`로 프로세스가
    /// 끝날 때까지 막혀 있어서, 자식이 조각을 흘려 보내도 호출자는 마지막에 한 덩어리로만
    /// 받는다.
    ///
    /// stderr를 nullDevice로 버리는 이유는 `run(_:_:)`과 같다 — Pipe로 두고 읽지 않으면
    /// 자식이 파이프 버퍼를 채운 순간 write에서 블록되고 stdout이 더 이상 흐르지 않는다.
    /// stdin도 nullDevice로 준다. 열어 두면 CLI가 파이프 입력을 기다리며 몇 초를 버린다.
    /// - Important: `Process`는 스레드 안전하지 않다. 그래서 프로세스를 만지는 일은 전부
    ///   전용 직렬 큐에서만 한다. 종료 대기에 `waitUntilExit()`를 쓰지 않고
    ///   `terminationHandler`를 쓰는 이유도 같다 — 다른 스레드에서 기다리는 동안 취소가
    ///   들어와 `terminate()`가 겹치면 내부 상태가 깨져 스트림이 영구히 끝나지 않는다.
    static func streamLines(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> AsyncStream<ShellStreamEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory { process.currentDirectoryURL = workingDirectory }

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            // 프로세스 상태를 만지는 모든 코드가 여기로 모인다.
            let queue = DispatchQueue(label: "com.jimmy.disktidy.shell-stream")
            // `terminate()`가 자식의 stdout을 닫아 아래 읽기가 풀린다.
            let watchdog: DispatchWorkItem? = timeout == nil
                ? nil
                : DispatchWorkItem { if process.isRunning { process.terminate() } }
            let state = StreamState(continuation: continuation, watchdog: watchdog)

            // stdout이 EOF가 되는 것과 자식이 죽는 것은 순서가 정해져 있지 않다.
            // 둘 다 도착했을 때만 종료 코드를 올린다.
            process.terminationHandler = { finished in
                let code = finished.terminationStatus
                queue.async { state.processExited(code: code) }
            }

            do {
                try process.run()
            } catch {
                // 실행 자체가 안 된 것도 종료 코드로 알린다. 사유 문구는 호출자가 만든다.
                continuation.yield(.exit(-1))
                continuation.finish()
                return
            }

            if let timeout, let watchdog {
                queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            }

            let readTask = Task.detached(priority: .userInitiated) {
                do {
                    for try await line in outPipe.fileHandleForReading.bytes.lines {
                        continuation.yield(.line(line))
                    }
                } catch {
                    // 읽기가 끊긴 것은 EOF로 취급한다. 사유는 종료 코드가 말한다.
                }
                queue.async {
                    state.cancelWatchdog()
                    state.outputEnded()
                }
            }

            continuation.onTermination = { _ in
                readTask.cancel()
                queue.async {
                    state.cancelWatchdog()
                    if process.isRunning { process.terminate() }
                }
            }
        }
    }


    /// stderr는 nullDevice로 버린다. Pipe로 두면 자식이 파이프 버퍼(64KB)를
    /// 채운 순간 write에서 블록되고, 부모는 stdout 읽기에서 영구 대기한다.
    /// `find`가 뿜는 "Permission denied"만으로도 쉽게 넘는 양이라 실제로 앱이 멈춘다.
    /// `timeout`을 주면 그 시간이 지나면 자식을 종료시킨다. 응답 없는 명령(로그인이 만료된
    /// CLI 등)에 영구히 매달리지 않기 위한 것이다. 취소 수단이 없으면 채팅이 영원히 돈다.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(output: "", exitCode: -1)
        }

        // `terminate()`가 자식의 stdout을 닫아 아래 읽기가 풀린다.
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
            watchdog = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
        return ShellResult(
            // `String(data:encoding:)`는 비UTF8 바이트가 하나만 섞여도 nil이다. 그러면
            // exFAT·SMB 볼륨의 파일명 하나 때문에 `lsof`·`du` 출력 전체가 사라진다.
            // 손상된 바이트만 치환문자로 바꾸고 나머지 줄은 살린다.
            output: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    @discardableResult
    static func runXcrun(_ arguments: [String]) -> ShellResult {
        run("/usr/bin/xcrun", arguments)
    }
}
