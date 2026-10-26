import Foundation

/// The sessions helper's entry point: `agterm --sessions-helper --socket <path> --build <id>`.
/// The helper owns every tab's shell so it survives the app quitting (see SessionServer). It is
/// the app's own executable, so macOS privacy checks for its shells (Full Disk Access and the
/// like) see agterm's code identity even after the app quits.
public enum SessionHelperMain {
    public static let flag = "--sessions-helper"

    public static func run(arguments: [String]) -> Never {
        guard let socketPath = value(of: "--socket", in: arguments) else {
            FileHandle.standardError.write(Data("usage: agterm \(flag) --socket <path> --build <id>\n".utf8))
            exit(2)
        }
        daemonize()
        do {
            try SessionServer(socketPath: socketPath, build: value(of: "--build", in: arguments) ?? "unknown").run()
        } catch {
            FileHandle.standardError.write(Data("agterm sessions helper: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    private static func value(of name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// A daemon: own session, no terminal, nothing held open in the app's working directory.
    private static func daemonize() {
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        chdir("/")
        let devNull = open("/dev/null", O_RDWR)
        guard devNull >= 0 else { return }
        dup2(devNull, STDIN_FILENO)
        dup2(devNull, STDOUT_FILENO)
        #if !DEBUG
        dup2(devNull, STDERR_FILENO)
        #endif
        if devNull > STDERR_FILENO { close(devNull) }
    }
}
