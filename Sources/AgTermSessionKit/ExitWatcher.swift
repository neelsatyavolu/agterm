import Foundation

/// Calls `handler` on `queue` once the child `pid` has exited, leaving it for the caller to reap.
/// `cancel` (on `queue`) stops a later call.
final class ExitWatcher {
    #if canImport(Darwin)
    private let source: DispatchSourceProcess

    init(pid: pid_t, queue: DispatchQueue, handler: @escaping () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func cancel() { source.cancel() }
    #else
    // Linux's libdispatch has no process sources: a thread waits for the exit. WNOWAIT leaves the
    // child a zombie, so `reap` still collects its status; once it's reaped the wait returns too.
    /// Read and written only on `queue`.
    private final class State: @unchecked Sendable { var cancelled = false }
    private let state = State()

    init(pid: pid_t, queue: DispatchQueue, handler: @escaping () -> Void) {
        let state = state
        let thread = Thread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
            queue.async { if !state.cancelled { handler() } }
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }

    func cancel() { state.cancelled = true }
    #endif
}
