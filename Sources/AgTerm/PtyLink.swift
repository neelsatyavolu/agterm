import AgTermCore
import Foundation
import SwiftTerm

/// A tab's connection to its shell: in the sessions helper (`HelperLink`), or a child
/// of the app (`LocalLink`) when the helper can't be used. Main queue only.
protocol PtyLink: AnyObject {
    var shellPid: pid_t { get }
    /// The pty master, for the foreground job and signals; -1 once the link is closed.
    var ptyFd: Int32 { get }
    /// The helper's id for the session; nil for a local shell.
    var sessionID: String? { get }
    /// Output for the screen, in order. Set before the current main-queue turn ends.
    var onData: (([UInt8]) -> Void)? { get set }
    /// The shell exited with this status (nil if unknown or unreachable).
    var onExit: ((Int32?) -> Void)? { get set }
    func write(_ bytes: ArraySlice<UInt8>)
    /// Rows and columns, plus the pixel size some programs read.
    func resize(_ size: winsize)
    /// Ends the shell: SIGHUP to it and its foreground job, SIGKILL if it is still there after 2 s.
    func end()
    /// Stops showing the shell but leaves it running, for a later attach.
    func detach()
}

/// A shell run by SwiftTerm's `LocalProcess`, as every tab was before the helper. It dies with
/// the app, so `detach()` ends it.
final class LocalLink: PtyLink, LocalProcessDelegate {
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32?) -> Void)?
    let sessionID: String? = nil
    private var process: LocalProcess!
    private var size: winsize
    private var ended = false

    var shellPid: pid_t { process.shellPid }
    var ptyFd: Int32 { process.childfd }

    /// `argv[0]` is the name the shell sees (`-zsh` for a login shell).
    init(_ request: SpawnRequest, size: winsize) {
        self.size = size
        process = LocalProcess(delegate: self)
        process.startProcess(executable: request.executable, args: Array(request.argv.dropFirst()),
                             environment: request.env, execName: request.argv.first, currentDirectory: request.cwd)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        process.send(data: bytes)
    }

    func resize(_ size: winsize) {
        self.size = size
        guard process.running else { return }
        var size = size
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    /// The way Terminal.app closes a tab, then reaps the shell: LocalProcess stops watching the
    /// child on terminate, so without the wait every closed tab would leave a zombie.
    func end() {
        guard !ended else { return }
        ended = true
        let pid = process.shellPid
        let fg = ProcInfo.foregroundPid(ptyFd: process.childfd)
        if pid > 0 { kill(pid, SIGHUP) }
        if let fg, fg != pid { killpg(fg, SIGHUP) }
        process.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    func detach() {
        end()
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        onData?(Array(slice))
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }

    func getWindowSize() -> winsize {
        size
    }
}
