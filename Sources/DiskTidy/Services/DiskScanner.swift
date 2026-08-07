import Foundation

enum DiskScanner {
    /// `du -sk`는 인자를 여러 개 받아 경로별로 한 줄씩 출력한다.
    /// 엔트리마다 프로세스를 띄우면 `~/Library/Caches`(100개 이상)에서만
    /// 100번 넘게 fork/exec 하므로 한 번에 묶어 부른다.
    /// 인자 길이 상한(ARG_MAX)에 걸리지 않도록 청크로 나눈다.
    static func sizes(of urls: [URL]) -> [URL: Int64] {
        guard !urls.isEmpty else { return [:] }

        var byPath: [String: Int64] = [:]
        for chunk in urls.chunked(into: 200) {
            let result = ShellRunner.run("/usr/bin/du", ["-sk"] + chunk.map(\.path))
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                byPath[String(parts[1])] = kb * 1024
            }
        }

        return urls.reduce(into: [:]) { result, url in
            result[url] = byPath[url.path] ?? 0
        }
    }

    static func sizeOfDirectory(_ url: URL) -> Int64 {
        sizes(of: [url])[url] ?? 0
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
