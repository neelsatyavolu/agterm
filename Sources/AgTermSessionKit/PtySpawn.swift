import AgTermCore
import Foundation

/// `forkpty` + `execve`, like SwiftTerm's `PseudoTerminalHelpers.fork(andExec:)` (forkpty
/// already makes the child a session leader with the pty as its controlling terminal), plus
/// the child clean-up a daemon parent needs: the helper ignores SIGHUP and SIGPIPE, and
/// ignored signals survive exec, so without resetting them a shell could not be hung up.
enum PtySpawn {
    /// Highest descriptor the child closes before exec; everything of ours is close-on-exec anyway.
    private static let closeLimit: Int32 = 4096

    static func fork(_ request: SpawnRequest) throws -> (pid: pid_t, masterFd: Int32) {
        guard !request.executable.isEmpty, !request.argv.isEmpty else { throw POSIXError(.EINVAL) }
        // Everything the child touches is prepared before fork: after it, only async-signal-safe calls.
        let argv = CStrings(request.argv)
        let env = CStrings(request.env)
        defer { argv.free(); env.free() }
        guard let path = strdup(request.executable) else { throw POSIXError(.ENOMEM) }
        defer { free(path) }
        guard let cwd = strdup(request.cwd) else { throw POSIXError(.ENOMEM) }
        defer { free(cwd) }
        let lastFD = min(getdtablesize(), closeLimit)
        var size = winsize(ws_row: request.rows, ws_col: request.cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1

        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { throw POSIXError.current }
        if pid == 0 {
            var none = sigset_t()
            sigprocmask(SIG_SETMASK, &none, nil)
            for sig in 1..<Int32(32) where sig != SIGKILL && sig != SIGSTOP { signal(sig, SIG_DFL) }
            var fd: Int32 = 3
            while fd < lastFD { Foundation.close(fd); fd += 1 }
            _ = chdir(cwd)
            execve(path, argv.base, env.base)
            _exit(127)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }

    /// A NULL-terminated `char *[]`.
    private struct CStrings {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int

        init(_ strings: [String]) {
            count = strings.count
            base = .allocate(capacity: strings.count + 1)
            for (index, string) in strings.enumerated() { base[index] = strdup(string) }
            base[strings.count] = nil
        }

        func free() {
            for index in 0..<count { Foundation.free(base[index]) }
            base.deallocate()
        }
    }
}
