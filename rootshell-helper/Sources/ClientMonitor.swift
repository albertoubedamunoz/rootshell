//
//  ClientMonitor.swift
//  rootshell-helper
//
//  Monitors client app processes using kqueue EVFILT_PROC.
//  Detects when the Catalyst app exits (crash or normal) and triggers session cleanup.
//

import Foundation

/// Monitors client processes for exit events using kqueue
class ClientMonitor {
    static let shared = ClientMonitor()

    private var kq: Int32 = -1
    private var monitoredPIDs: Set<pid_t> = []
    private let lock = NSLock()
    private var isRunning = false
    private var isKqueueValid = false  // Track if kqueue is actually usable
    private var monitorQueue: DispatchQueue

    /// Callback when a client process exits
    var onClientExit: ((pid_t) -> Void)?

    private init() {
        monitorQueue = DispatchQueue(
            label: "com.kk2.rootshell.helper.clientmonitor",
            qos: .utility
        )

        createKqueue()
    }

    /// Create or recreate the kqueue
    private func createKqueue() {
        lock.lock()
        defer { lock.unlock() }

        // Close existing kqueue if any
        if kq >= 0 {
            close(kq)
        }

        kq = kqueue()
        if kq < 0 {
            NSLog("ClientMonitor: Failed to create kqueue: \(errno)")
            isKqueueValid = false
        } else {
            NSLog("ClientMonitor: Created kqueue fd=\(kq)")
            isKqueueValid = true
            startMonitorLoop()
        }
    }

    deinit {
        shutdown()
    }

    /// Cleanly shutdown the monitor
    func shutdown() {
        guard isRunning else { return }
        isRunning = false
        // Note: Don't close kq here - let the monitor loop exit naturally
        // Closing while kevent() is blocked can cause issues
        NSLog("ClientMonitor: Shutdown requested")
    }

    /// Start monitoring a client PID for exit.
    /// Safe to call multiple times with the same PID.
    func monitorClient(_ pid: pid_t) {
        guard pid > 0 else { return }

        lock.lock()

        // Check if kqueue is valid
        guard isKqueueValid && kq >= 0 else {
            lock.unlock()
            NSLog("ClientMonitor: kqueue not available, cannot monitor PID \(pid)")
            return
        }

        // Already monitoring this PID
        guard !monitoredPIDs.contains(pid) else {
            lock.unlock()
            return
        }

        // Check if process is still alive before monitoring
        if kill(pid, 0) != 0 && errno == ESRCH {
            lock.unlock()
            NSLog("ClientMonitor: PID \(pid) already dead, not monitoring")
            return
        }

        // Add EVFILT_PROC kevent to watch for process exit
        var kev = Darwin.kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )

        let currentKq = kq  // Capture under lock
        lock.unlock()

        // Verify fd is still valid before using it
        let fdValid = fcntl(currentKq, F_GETFD) >= 0
        if !fdValid {
            NSLog("ClientMonitor: kqueue fd \(currentKq) is invalid (fcntl check failed), errno=\(errno)")
            lock.lock()
            isKqueueValid = false
            lock.unlock()
            return
        }

        let result = kevent(currentKq, &kev, 1, nil, 0, nil)
        if result < 0 {
            let err = errno
            NSLog("ClientMonitor: Failed to monitor PID \(pid): errno=\(err), kq=\(currentKq)")
            if err == EBADF {
                // kqueue became invalid, mark it
                lock.lock()
                isKqueueValid = false
                lock.unlock()
            }
            return
        }

        lock.lock()
        monitoredPIDs.insert(pid)
        lock.unlock()
        NSLog("ClientMonitor: Now monitoring client PID \(pid)")
    }

    /// Stop monitoring a client PID.
    /// Called when all sessions for a client have been removed.
    func stopMonitoring(_ pid: pid_t) {
        guard pid > 0 else { return }

        lock.lock()

        guard isKqueueValid && kq >= 0 else {
            // Just remove from our tracking if kqueue is invalid
            monitoredPIDs.remove(pid)
            lock.unlock()
            return
        }

        guard monitoredPIDs.contains(pid) else {
            lock.unlock()
            return
        }

        // Remove the kevent (may fail if already fired due to EV_ONESHOT, that's ok)
        var kev = Darwin.kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_DELETE),
            fflags: 0,
            data: 0,
            udata: nil
        )

        let currentKq = kq
        monitoredPIDs.remove(pid)
        lock.unlock()

        kevent(currentKq, &kev, 1, nil, 0, nil)
        NSLog("ClientMonitor: Stopped monitoring client PID \(pid)")
    }

    /// Check if a PID is currently being monitored
    func isMonitoring(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return monitoredPIDs.contains(pid)
    }

    private func startMonitorLoop() {
        // Prevent starting multiple loops
        guard !isRunning else {
            NSLog("ClientMonitor: Monitor loop already running")
            return
        }
        isRunning = true

        monitorQueue.async { [weak self] in
            self?.monitorLoop()
        }
    }

    private func monitorLoop() {
        // Create event buffer for receiving events
        var events = [Darwin.kevent](repeating: Darwin.kevent(
            ident: 0,
            filter: 0,
            flags: 0,
            fflags: 0,
            data: 0,
            udata: nil
        ), count: 16)

        while isRunning && kq >= 0 {
            // Wait for events with 1 second timeout (allows clean shutdown)
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            let nevents = kevent(kq, nil, 0, &events, Int32(events.count), &timeout)

            if nevents < 0 {
                let err = errno
                if err == EBADF {
                    // kqueue file descriptor is invalid, mark it and stop the loop
                    lock.lock()
                    isKqueueValid = false
                    lock.unlock()
                    NSLog("ClientMonitor: kqueue FD is invalid (EBADF), stopping monitor loop")
                    break
                }
                if err != EINTR {
                    NSLog("ClientMonitor: kevent error: \(err)")
                    // Add small delay on unexpected errors to prevent spin loop
                    usleep(100_000)  // 100ms
                }
                continue
            }

            for i in 0..<Int(nevents) {
                let event = events[i]

                // Check for process exit event
                if event.filter == Int16(EVFILT_PROC) &&
                   (event.fflags & UInt32(NOTE_EXIT)) != 0 {
                    let pid = pid_t(event.ident)
                    handleClientExit(pid)
                }
            }
        }

        // Mark as not running so it could potentially be restarted
        isRunning = false
        NSLog("ClientMonitor: Monitor loop ended")
    }

    private func handleClientExit(_ pid: pid_t) {
        // Remove from our tracking (EV_ONESHOT already removed it from kqueue)
        lock.lock()
        let wasMonitored = monitoredPIDs.remove(pid) != nil
        let remainingCount = monitoredPIDs.count
        lock.unlock()

        guard wasMonitored else {
            NSLog("ClientMonitor: Received exit event for unknown PID \(pid)")
            return
        }

        NSLog("ClientMonitor: Client PID \(pid) exited, \(remainingCount) PIDs still monitored")

        // Notify on main queue for thread safety with SessionManager
        DispatchQueue.main.async { [weak self] in
            self?.onClientExit?(pid)
        }
    }
}
