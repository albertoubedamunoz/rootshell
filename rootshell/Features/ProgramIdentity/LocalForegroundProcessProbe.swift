//
//  LocalForegroundProcessProbe.swift
//  rootshell
//
//  Reads a local PTY's foreground process group straight from the master fd
//  the app already holds. The process lookups are best effort: a sandbox
//  that hides other processes leaves the identity unknown.
//

#if targetEnvironment(macCatalyst)
import Darwin
import Foundation

nonisolated enum LocalForegroundProcessProbe {
    /// The foreground process group, or nil when the PTY has none. One
    /// ioctl, cheap enough to call on every coalesced content change.
    static func foregroundProcessGroup(masterFD: Int32) -> pid_t? {
        guard masterFD >= 0 else { return nil }
        let group = tcgetpgrp(masterFD)
        return group > 0 ? group : nil
    }

    /// Identity of the group's leader. The leader is the job a shell
    /// started, so `sudo htop` reports sudo's argv and unwraps to htop.
    static func program(processGroup: pid_t) -> ForegroundProgram? {
        let arguments = arguments(of: processGroup)
        guard let rawName = arguments.first ?? executablePath(of: processGroup) else { return nil }
        return ForegroundProgram(rawName: rawName, arguments: arguments, source: .localProcess)
    }

    private typealias ProcPidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static let procPidPathFn: ProcPidPathFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return nil }
        return unsafeBitCast(sym, to: ProcPidPathFn.self)
    }()

    static func executablePath(of pid: pid_t) -> String? {
        guard let procPidPathFn else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            procPidPathFn(pid, $0.baseAddress!, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let maxArguments = 16
    private static let maxArgumentBytes = 256

    /// argv from KERN_PROCARGS2: argc, the exec path, NUL padding, then the
    /// arguments, each NUL-terminated.
    private static func arguments(of pid: pid_t) -> [String] {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argMaxMIB = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMIB, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return [] }

        // Revalidation runs this every few seconds; only the bytes sysctl
        // writes are read, so skip zero-filling the ARG_MAX-sized buffer.
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let buffer = [UInt8](unsafeUninitializedCapacity: Int(argMax)) { storage, count in
            size = storage.count
            count = sysctl(&mib, 3, storage.baseAddress, &size, nil, 0) == 0 ? size : 0
        }
        size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = MemoryLayout<Int32>.size
        // Skip the exec path and the padding after it.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        while arguments.count < min(Int(argc), maxArguments), cursor < size {
            guard let end = buffer[cursor..<size].firstIndex(of: 0) else { break }
            let bytes = buffer[cursor..<min(end, cursor + maxArgumentBytes)]
            arguments.append(String(decoding: bytes, as: UTF8.self))
            cursor = end + 1
        }
        return arguments
    }
}
#endif
