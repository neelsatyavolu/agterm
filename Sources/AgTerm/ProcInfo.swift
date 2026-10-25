import Darwin
import Foundation

/// Cheap syscalls for what a tab is running and where.
enum ProcInfo {
    /// The process group in the foreground of the pty: the shell, or whatever it launched.
    static func foregroundPid(ptyFd: Int32) -> pid_t? {
        guard ptyFd >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFd)
        return pgid > 0 ? pgid : nil
    }

    static func cwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    static func name(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv, read from the kernel (KERN_PROCARGS2: argc, exec path, then argv).
    static func arguments(pid: pid_t) -> [String] {
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

    /// The conversation a running Claude Code process is in, from its record in ~/.claude/sessions.
    static func claudeSessionID(pid: pid_t) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = record["sessionId"] as? String,
              id.range(of: #"^[0-9A-Za-z-]{8,64}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
