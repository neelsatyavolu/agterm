import XCTest
@testable import AgTermCore

final class InheritedEnvironmentTests: XCTestCase {
    private let accounts = "/Users/me/Library/Application Support/co.xanom.agterm/accounts"

    func testDropsAnAgentSessionsMarkersAndAccountFolder() {
        let env = ["CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_PID": "9",
                   "AGTERM_TAB_ID": "t", "AGTERM_BIN": "/b", "CLAUDE_CONFIG_DIR": accounts + "/8d9c", "CODEX_HOME": "/Users/me/.codex",
                   "PATH": "/usr/bin", "HOME": "/Users/me"]
        XCTAssertEqual(InheritedEnvironment.toDrop(env, accountsDir: accounts),
                       ["AGTERM_BIN", "AGTERM_TAB_ID", "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "CLAUDE_PID"])
    }

    /// Opened normally, even your own settings that look like these stay.
    func testKeepsEverythingWhenNotOpenedFromASession() {
        let env = ["CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CONFIG_DIR": accounts + "/x", "PATH": "/usr/bin"]
        XCTAssertEqual(InheritedEnvironment.toDrop(env, accountsDir: accounts), [])
    }

    func testKeepsALoginFolderOutsideAgterms() {
        let env = ["AGTERM_TAB_ID": "t", "CLAUDE_CONFIG_DIR": "/Users/me/claude-work", "CODEX_HOME": accounts]
        XCTAssertEqual(InheritedEnvironment.toDrop(env, accountsDir: accounts), ["AGTERM_TAB_ID", "CODEX_HOME"])
    }
}
