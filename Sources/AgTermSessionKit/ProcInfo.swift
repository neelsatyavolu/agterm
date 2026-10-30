import Foundation

/// Cheap syscalls for what a tab is running and where: libproc on macOS, /proc on Linux (a
/// cloud machine's helper reports the same things to the app, see `ForegroundInfo`).
public enum ProcInfo {
    /// The process group in the foreground of the pty: the shell, or whatever it launched.
    public static func foregroundPid(ptyFd: Int32) -> pid_t? {
        guard ptyFd >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFd)
        return pgid > 0 ? pgid : nil
    }

    #if canImport(Darwin)
    public static func cwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// When `pid` started; nil if there is no such process (or it isn't ours to inspect).
    public static func startTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    public static func name(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv, read from the kernel (KERN_PROCARGS2: argc, exec path, then argv).
    public static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // exec path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// Paths of regular files open in any process of a process group. A running Codex holds its
    /// rollout open, which pins a tab to its exact conversation.
    public static func openFiles(group pgid: pid_t, matching keep: (String) -> Bool) -> [String] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        var paths: [String] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if keep(path) { paths.append(path) }
            }
        }
        return paths
    }

    #else
    public static func cwd(pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
    }

    public static func name(pid: pid_t) -> String? {
        guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return nil }
        let name = comm.trimmingCharacters(in: .newlines)
        return name.isEmpty ? nil : name
    }

    /// The process's argv, from /proc/<pid>/cmdline (NUL-separated).
    public static func arguments(pid: pid_t) -> [String] {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return [] }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    /// Paths of regular files open in any process of a process group.
    public static func openFiles(group pgid: pid_t, matching keep: (String) -> Bool) -> [String] {
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { pid_t($0) }
        var paths: [String] = []
        for pid in pids where processGroup(pid) == pgid {
            let dir = "/proc/\(pid)/fd"
            for fd in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/" + fd),
                      path.hasPrefix("/"), keep(path) else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    /// Field 5 of /proc/<pid>/stat; the name before it is in parentheses and may hold spaces.
    private static func processGroup(_ pid: pid_t) -> pid_t? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 2 ? pid_t(fields[2]) : nil
    }

    #endif

    /// The conversation a running Claude Code process is in, from its record in ~/.claude/sessions.
    public static func claudeSessionID(pid: pid_t) -> String? { claudeSession(pid: pid)?.id }

    /// Claude Code's record of a running session: its id, and whether it's busy with a turn
    /// (`status` "busy"/"idle"; nil on versions that don't write it).
    public static func claudeSession(pid: pid_t, home: String = NSHomeDirectory()) -> (id: String, busy: Bool?)? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = record["sessionId"] as? String,
              id.range(of: #"^[0-9A-Za-z-]{8,64}$"#, options: .regularExpression) != nil else { return nil }
        let status = record["status"] as? String
        return (id, status == "busy" ? true : status == "idle" ? false : nil)
    }

    public static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
