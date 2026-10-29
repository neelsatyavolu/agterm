import XCTest
@testable import AgTermCore

final class TabNameTests: XCTestCase {
    func testNameIsTrimmed() {
        XCTAssertEqual(TabName.cleaned("  api server \n"), "api server")
    }

    func testBlankNameClearsIt() {
        XCTAssertNil(TabName.cleaned("   "))
        XCTAssertNil(TabName.cleaned(""))
    }

    func testLineBreaksBecomeSpaces() {
        XCTAssertEqual(TabName.cleaned("fix\nlogin"), "fix login")
    }

    func testSavedNameRoundTrips() throws {
        let workspace = SavedWorkspace(selected: 0, tabs: [SavedTab(cwd: "/a", scrollback: "", resume: nil, name: "deploy")])
        XCTAssertEqual(try SavedWorkspace.decode(workspace.encoded()).tabs.first?.name, "deploy")
    }

    func testSavesFromBeforeNamesHaveNone() throws {
        let old = #"{"version":1,"savedAt":0,"selected":0,"tabs":[{"cwd":"/a","scrollback":""}]}"#
        XCTAssertNil(try SavedWorkspace.decode(Data(old.utf8)).tabs.first?.name)
    }
}
