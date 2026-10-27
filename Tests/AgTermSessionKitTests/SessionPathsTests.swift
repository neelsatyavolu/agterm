import AgTermSessionKit
import XCTest

final class SessionPathsTests: XCTestCase {
    private let arguments = ["/Applications/agterm.app/Contents/MacOS/agterm", "--sessions-helper",
                             "--socket", "/tmp/agterm-501/ada3d307.sock", "--build", "1.0.6"]

    func testHelperJobLabelIsStableForTheSameArguments() {
        let label = SessionPaths.helperJobLabel(arguments: arguments)
        XCTAssertEqual(label, SessionPaths.helperJobLabel(arguments: arguments))
        XCTAssertTrue(label.hasPrefix("co.xanom.agterm.sessions."))
        XCTAssertEqual(label.count, "co.xanom.agterm.sessions.".count + 8)
    }

    /// A loaded job's arguments can't change, so another build or binary needs another label.
    func testHelperJobLabelDiffersForOtherArguments() {
        var otherBuild = arguments
        otherBuild[5] = "1.0.7"
        var otherSocket = arguments
        otherSocket[3] = "/tmp/agterm-501/0badf00d.sock"
        let label = SessionPaths.helperJobLabel(arguments: arguments)
        XCTAssertNotEqual(label, SessionPaths.helperJobLabel(arguments: otherBuild))
        XCTAssertNotEqual(label, SessionPaths.helperJobLabel(arguments: otherSocket))
    }
}
