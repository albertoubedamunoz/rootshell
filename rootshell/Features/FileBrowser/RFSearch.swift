#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Ripgrep content search for the rf file browser.
/// Calls rg_main directly (like bat_main in RFPreview), bypassing ios_system_async.
@MainActor
final class RFSearch {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-search")

    /// Search for files containing the query using ripgrep.
    nonisolated static func search(query: String, directory: String) async -> [String] {
        let output = await runRipgrep(query: query, directory: directory)
        guard !output.isEmpty else { return [] }

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// Call rg_main directly, matching the proven bat_main pattern from RFPreview.
    nonisolated private static func runRipgrep(query: String, directory: String) async -> String {
        await withCheckedContinuation { continuation in
            RFToolSession.queue.async {
                var outPipe: [Int32] = [0, 0]
                var inPipe: [Int32] = [0, 0]
                guard pipe(&outPipe) == 0, pipe(&inPipe) == 0 else {
                    continuation.resume(returning: "")
                    return
                }
                let readFd = outPipe[0]
                let writeFd = outPipe[1]
                close(inPipe[1]) // We don't write to rg's stdin

                guard let stdinFile = fdopen(inPipe[0], "r"),
                      let stdoutFile = fdopen(writeFd, "w") else {
                    close(outPipe[0]); close(outPipe[1])
                    close(inPipe[0])
                    continuation.resume(returning: "")
                    return
                }

                ios_switchSession(RFToolSession.key)
                ios_setStreams(stdinFile, stdoutFile, stdoutFile)

                // Read pipe concurrently (prevents deadlock on large output)
                var outputData = Data()
                let readerQueue = DispatchQueue(label: "rf.rg.reader")
                let readerDone = DispatchSemaphore(value: 0)

                readerQueue.async {
                    let bufSize = 16384
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { buf.deallocate() }
                    while true {
                        let n = read(readFd, buf, bufSize)
                        if n <= 0 { break }
                        outputData.append(buf, count: n)
                    }
                    close(readFd)
                    readerDone.signal()
                }

                // Build argv for rg_main
                let args = ["rg", "--files-with-matches", "--smart-case", query, directory]

                let cArgs = args.map { strdup($0) }
                defer { cArgs.forEach { free($0) } }
                var argv: [UnsafePointer<CChar>?] = cArgs.map { $0.flatMap { UnsafePointer($0) } }

                _ = rg_main(Int32(args.count), &argv)

                fflush(stdoutFile)
                fclose(stdoutFile)
                fclose(stdinFile)
                ios_setStreams(stdin, stdout, stderr)

                let waitResult = readerDone.wait(timeout: .now() + 5.0)
                if waitResult == .timedOut {
                    close(readFd)
                    readerDone.wait()
                }

                let result = String(data: outputData, encoding: .utf8) ?? ""
                continuation.resume(returning: result)
            }
        }
    }
}

#endif
