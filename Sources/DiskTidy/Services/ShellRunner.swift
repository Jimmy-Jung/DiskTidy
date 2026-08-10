import Foundation

/// 외부 명령 실행 결과.
struct ShellResult {
    let output: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

enum ShellRunner {
    /// stderr는 nullDevice로 버린다. Pipe로 두면 자식이 파이프 버퍼(64KB)를
    /// 채운 순간 write에서 블록되고, 부모는 stdout 읽기에서 영구 대기한다.
    /// `find`가 뿜는 "Permission denied"만으로도 쉽게 넘는 양이라 실제로 앱이 멈춘다.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(output: "", exitCode: -1)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
