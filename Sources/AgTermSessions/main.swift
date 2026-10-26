import AgTermSessionKit
import Foundation

// agterm-sessions --socket <path> --build <id>
// Owns every tab's shell so it survives the app quitting; see SessionServer.

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let socketPath = argument("--socket") else {
    FileHandle.standardError.write(Data("usage: agterm-sessions --socket <path> --build <id>\n".utf8))
    exit(2)
}

// A daemon: own session, no terminal, nothing held open in the app's working directory.
setsid()
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
chdir("/")
let devNull = open("/dev/null", O_RDWR)
if devNull >= 0 {
    dup2(devNull, STDIN_FILENO)
    dup2(devNull, STDOUT_FILENO)
    #if !DEBUG
    dup2(devNull, STDERR_FILENO)
    #endif
    if devNull > STDERR_FILENO { close(devNull) }
}

do {
    try SessionServer(socketPath: socketPath, build: argument("--build") ?? "unknown").run()
} catch {
    FileHandle.standardError.write(Data("agterm-sessions: \(error)\n".utf8))
    exit(1)
}
