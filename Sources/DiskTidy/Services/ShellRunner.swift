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
            output: String(data: data, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    @discardableResult
    static func runXcrun(_ arguments: [String]) -> ShellResult {
        run("/usr/bin/xcrun", arguments)
    }
}
