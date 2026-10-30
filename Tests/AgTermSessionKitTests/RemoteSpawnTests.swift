import AgTermCore
@testable import AgTermSessionKit
import XCTest

final class RemoteSpawnTests: XCTestCase {
    private let account = RemoteSpawn.Account(user: "neel", home: "/Users/neel", shell: "/bin/bash", path: "/usr/bin:/bin")

    func testRunsThisMachinesLoginShellWithItsEnvironment() {
        let request = SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"],
                                   env: ["TERM=xterm-256color", "LC_ALL=C", "AGTERM_TAB_ID=t1", "AGTERM_BIN=/Applications/agterm",
                                         "OPENAI_API_KEY=sk", "PATH=/opt/homebrew/bin", "HOME=/elsewhere"],
                                   cwd: "/Users/neel/code", cols: 120, rows: 40)
        let local = RemoteSpawn.localize(request, for: account) { $0 == "/Users/neel/code" }
        XCTAssertEqual(local.executable, "/bin/bash")
        XCTAssertEqual(local.argv, ["-bash"])
        XCTAssertEqual(local.env, ["HOME=/Users/neel", "USER=neel", "LOGNAME=neel", "SHELL=/bin/bash", "PATH=/usr/bin:/bin",
                                   "TERM=xterm-256color", "LC_ALL=C", "AGTERM_TAB_ID=t1"])
        XCTAssertEqual(local.cwd, "/Users/neel/code")
        XCTAssertEqual([local.cols, local.rows], [120, 40])
    }

    func testMissingOrRelativeFolderFallsBackToHome() {
        let missing = SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: [], cwd: "/Users/neel/gone", cols: 80, rows: 24)
        XCTAssertEqual(RemoteSpawn.localize(missing, for: account) { _ in false }.cwd, "/Users/neel")
        let relative = SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: [], cwd: "code", cols: 80, rows: 24)
        XCTAssertEqual(RemoteSpawn.localize(relative, for: account) { _ in true }.cwd, "/Users/neel")
    }

    func testParsesEndpoints() {
        XCTAssertEqual(TCPSocket.parse("127.0.0.1:7600")?.host, "127.0.0.1")
        XCTAssertEqual(TCPSocket.parse("127.0.0.1:7600")?.port, 7600)
        XCTAssertEqual(TCPSocket.parse("[::1]:22")?.host, "::1")
        XCTAssertNil(TCPSocket.parse("host"))
        XCTAssertNil(TCPSocket.parse(":7600"))
        XCTAssertNil(TCPSocket.parse("host:99999"))
    }
}
