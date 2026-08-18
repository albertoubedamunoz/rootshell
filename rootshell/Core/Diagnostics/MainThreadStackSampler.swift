//
//  MainThreadStackSampler.swift
//  rootshell
//
//  Periodic main-thread stack sampler used to diagnose 0x8BADF00D scene-update
//  watchdog hangs on return from background. Runs only while
//  ForegroundTransitionWatchdog is armed; emits one
//  `FG.mainStackSample ordinal=N frames=...` checkpoint per sample to
//  LifecycleDebugLogger so post-mortem traces show where main was wedged.
//
//  Reads main-thread register state via `thread_get_state` without suspending
//  (the failure path has main blocked, so the snapshot is stable). Walks the
//  ARM64 frame chain via `mach_vm_read_overwrite` so unmapped pages return
//  errors instead of crashing the sampler. Symbolicates with `dladdr` —
//  raw mangled Swift names; decode with `xcrun swift-demangle` after the fact.
//

import Foundation
import Darwin
import os

#if targetEnvironment(macCatalyst)

// Mac Catalyst ships a universal (arm64 + x86_64) binary, but this sampler
// reads ARM64 register state and walks the ARM frame chain — it can't build
// on x86_64. Lifecycle debug isn't used on macOS, so stub the API out
// entirely and let the call sites stay untouched.
final class MainThreadStackSampler: Sendable {
    nonisolated static let shared = MainThreadStackSampler()
    private init() {}

    static func installOnMainThread() {}
    nonisolated func start(token: UInt64) {}
    nonisolated func stop(reason: String) {}
}

#else

final class MainThreadStackSampler: Sendable {
    nonisolated static let shared = MainThreadStackSampler()

    nonisolated private static let maxSamplesPerArm = 40
    nonisolated private static let sampleInterval: TimeInterval = 0.25
    nonisolated private static let maxFrames = 16
    // Real Swift mangled symbols routinely exceed 96 chars. Cap above the
    // typical worst case so we keep the readable symbol form; longer ones
    // fall back to image+offset via formatFrame.
    nonisolated private static let maxSymbolLength = 256
    // Manual ARM_THREAD_STATE64_COUNT — the macro is unavailable on the
    // iPhoneSimulator SDK ("structure not supported"), but the wire format
    // is identical (struct of __uint64_t x[29], fp, lr, sp, pc + __uint32_t
    // cpsr, pad). Computed in `natural_t` (UInt32) units to match the
    // `thread_get_state` API.
    nonisolated private static let armThreadState64Count: mach_msg_type_number_t = {
        mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    }()

    private struct State: Sendable {
        var isSampling: Bool = false
        var samplesEmitted: Int = 0
        var armToken: UInt64 = 0
        // Generation increments on every start so a stale scheduled sample
        // (queued before stop ran) can self-cancel.
        var generation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let queue = DispatchQueue(label: "com.rootshell.mainStackSampler", qos: .utility)
    private let mainThreadPort = OSAllocatedUnfairLock<mach_port_t>(initialState: 0)

    private init() {}

    /// Capture the main thread's mach port so the sampler can read its state
    /// later from a background queue. MUST be called from the main thread.
    /// Idempotent: subsequent calls are no-ops once the port is captured.
    static func installOnMainThread() {
        precondition(Thread.isMainThread,
                     "MainThreadStackSampler.installOnMainThread must run on the main thread")
        let port = pthread_mach_thread_np(pthread_self())
        shared.mainThreadPort.withLock { existing in
            if existing == 0 {
                existing = port
            }
        }
    }

    /// Begin sampling. Safe to call from any thread; pairs with `stop`.
    nonisolated func start(token: UInt64) {
        let generation = state.withLock { state -> UInt64 in
            state.isSampling = true
            state.samplesEmitted = 0
            state.armToken = token
            state.generation &+= 1
            return state.generation
        }
        scheduleNext(generation: generation, initial: true)
    }

    /// Stop sampling. Emits a summary checkpoint with the count of samples
    /// taken during this arm. No-op if not currently sampling.
    nonisolated func stop(reason: String) {
        let summary = state.withLock { state -> (Int, UInt64)? in
            guard state.isSampling else { return nil }
            state.isSampling = false
            return (state.samplesEmitted, state.armToken)
        }
        guard let (samples, token) = summary else { return }
        LifecycleDebugLogger.shared.checkpoint("FG.mainStackSample.summary", ms: nil, [
            ("token", token),
            ("samples", samples),
            ("reason", reason),
        ])
    }

    private nonisolated func scheduleNext(generation: UInt64, initial: Bool) {
        // Use a small initial delay (50 ms) so transient transitions that
        // disarm immediately don't produce any sample noise.
        let delay = initial ? 0.05 : Self.sampleInterval
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            self.takeSampleIfStillRunning(generation: generation)
        }
    }

    private nonisolated func takeSampleIfStillRunning(generation: UInt64) {
        let snapshot: (proceed: Bool, ordinal: Int, token: UInt64, capped: Bool) = state.withLock { state in
            guard state.isSampling, state.generation == generation else {
                return (false, state.samplesEmitted, state.armToken, false)
            }
            if state.samplesEmitted >= Self.maxSamplesPerArm {
                state.isSampling = false
                return (false, state.samplesEmitted, state.armToken, true)
            }
            return (true, state.samplesEmitted + 1, state.armToken, false)
        }
        if snapshot.capped {
            LifecycleDebugLogger.shared.checkpoint("FG.mainStackSample.capped", ms: nil, [
                ("token", snapshot.token),
                ("samples", snapshot.ordinal),
            ])
            return
        }
        guard snapshot.proceed else { return }

        let port = mainThreadPort.withLock { $0 }
        if port == 0 {
            state.withLock { $0.isSampling = false }
            LifecycleDebugLogger.shared.checkpoint("FG.mainStackSample.error", ms: nil, [
                ("reason", "mainPortMissing"),
                ("token", snapshot.token),
            ])
            return
        }

        if let frames = sampleMainStack(mainPort: port) {
            LifecycleDebugLogger.shared.checkpoint("FG.mainStackSample", ms: nil, [
                ("token", snapshot.token),
                ("ordinal", snapshot.ordinal),
                ("frames", frames.joined(separator: ";")),
            ])
            state.withLock { $0.samplesEmitted = snapshot.ordinal }
            scheduleNext(generation: generation, initial: false)
        } else {
            state.withLock { $0.isSampling = false }
            LifecycleDebugLogger.shared.checkpoint("FG.mainStackSample.error", ms: nil, [
                ("reason", "thread_get_state_failed"),
                ("token", snapshot.token),
                ("ordinal", snapshot.ordinal),
            ])
        }
    }

    private nonisolated func sampleMainStack(mainPort: mach_port_t) -> [String]? {
        var threadState = arm_thread_state64_t()
        var stateCount = Self.armThreadState64Count

        let kr = withUnsafeMutablePointer(to: &threadState) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { rebound in
                thread_get_state(
                    mainPort,
                    thread_state_flavor_t(ARM_THREAD_STATE64),
                    rebound,
                    &stateCount
                )
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var frames: [String] = []
        let pc = stripPAC(threadState.__pc)
        if pc != 0 { frames.append(formatFrame(pc)) }

        let lr = stripPAC(threadState.__lr)
        if lr != 0, lr != pc { frames.append(formatFrame(lr)) }

        var fp = stripPAC(threadState.__fp)
        let task = mach_task_self_
        var prevFP: UInt64 = 0

        while frames.count < Self.maxFrames, fp != 0, fp != prevFP {
            prevFP = fp
            // ARM64 frame: [fp+0]=saved fp, [fp+8]=saved lr (return address).
            // Use vm_read_overwrite (Swift-auto-imported alias of the mach_vm_
            // variant for in-process reads) so corrupted FPs return errors
            // instead of crashing the sampler.
            var pair: (UInt64, UInt64) = (0, 0)
            let readResult = withUnsafeMutablePointer(to: &pair) { dst -> kern_return_t in
                var outSize: vm_size_t = 0
                return vm_read_overwrite(
                    task,
                    vm_address_t(fp),
                    vm_size_t(MemoryLayout<(UInt64, UInt64)>.size),
                    vm_address_t(UInt(bitPattern: dst)),
                    &outSize
                )
            }
            guard readResult == KERN_SUCCESS else { break }

            let savedLR = stripPAC(pair.1)
            if savedLR != 0 {
                frames.append(formatFrame(savedLR))
            }

            let nextFP = stripPAC(pair.0)
            // Stack grows downward, so each parent FP must be > child FP.
            // Bail on null, on regression, or on suspiciously small/large jumps.
            if nextFP == 0 || nextFP <= fp { break }
            fp = nextFP
        }
        return frames
    }

    /// iOS user-space addresses fit comfortably within 39 bits; PAC bits live
    /// above. Mask is a no-op on arm64 (simulator) where PAC isn't used.
    private nonisolated func stripPAC(_ ptr: UInt64) -> UInt64 {
        return ptr & 0x0000_007F_FFFF_FFFF
    }

    private nonisolated func formatFrame(_ addr: UInt64) -> String {
        var info = Dl_info()
        let raw = UnsafeRawPointer(bitPattern: UInt(addr))
        guard let raw, dladdr(raw, &info) != 0 else {
            return String(format: "0x%llx", addr)
        }

        // dladdr redacts app-private Swift / Obj-C symbols on iOS — `dli_sname`
        // comes back as the literal string "<redacted>". Offline symbolication
        // against the dSYM needs the image-relative offset, which dli_fbase
        // gives us even when the name is hidden.
        let imageBase = UInt(bitPattern: info.dli_fbase)
        let imageOffset = imageBase != 0 ? (UInt(addr) &- imageBase) : 0
        let imageBasename: String
        if let cfname = info.dli_fname {
            let path = String(cString: cfname)
            imageBasename = (path as NSString).lastPathComponent
        } else {
            imageBasename = "?"
        }

        let symbolName: String? = {
            guard let cname = info.dli_sname else { return nil }
            let raw = String(cString: cname)
            // System symbols come through; app symbols arrive as "<redacted>".
            // Treat redacted as no-symbol so offline atos has the image offset.
            if raw == "<redacted>" || raw.isEmpty { return nil }
            return raw
        }()

        // For symbols that exceed our display cap, fall back to the image
        // form so offline atos still works. A truncated mangled symbol with
        // ".." is unrecoverable, but `<image>@0x<offset>` is always atos-able.
        if let symbol = symbolName, symbol.count <= Self.maxSymbolLength {
            let saddr = UInt(bitPattern: info.dli_saddr)
            let offset = UInt(addr) &- saddr
            return "\(symbol)+\(offset)"
        }

        // No symbol, redacted, or too long — emit `<image>@0x<offsetHex>` for
        // offline atos: `xcrun atos -o <image-binary> -arch arm64 -l 0 0x<offset>`.
        return String(format: "%@@0x%llx", imageBasename, UInt64(imageOffset))
    }
}

#endif
