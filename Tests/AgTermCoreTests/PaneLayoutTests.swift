import AgTermCore
import XCTest

final class PaneLayoutTests: XCTestCase {
    private let rect = PaneRect(x: 0, y: 0, width: 1000, height: 600)

    func testSplittingPutsTheNewPaneBesideTheOld() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns)
        XCTAssertEqual(layout, .split(.columns, ratio: 0.5, .pane("a"), .pane("b")))
        XCTAssertEqual(layout.splitting("b", with: "c", axis: .rows).panes, ["a", "b", "c"])
    }

    func testSplittingAMissingPaneChangesNothing() {
        let layout = PaneNode.pane("a")
        XCTAssertEqual(layout.splitting("x", with: "b", axis: .rows), layout)
    }

    func testRemovingCollapsesTheSplit() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns).splitting("b", with: "c", axis: .rows)
        XCTAssertEqual(layout.removing("b"), .split(.columns, ratio: 0.5, .pane("a"), .pane("c")))
        XCTAssertEqual(layout.removing("a"), .split(.rows, ratio: 0.5, .pane("b"), .pane("c")))
        XCTAssertNil(PaneNode.pane("a").removing("a"))
    }

    func testKeepingDropsPanesThatDidNotComeBack() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns).splitting("b", with: "c", axis: .rows)
        XCTAssertEqual(layout.keeping(["a", "c"])?.panes, ["a", "c"])
        XCTAssertNil(layout.keeping([]))
    }

    func testReplacing() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns)
        XCTAssertEqual(layout.replacing("b", with: "z").panes, ["a", "z"])
    }

    func testFramesShareTheSpaceAroundTheGap() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns)
        let frames = layout.frames(in: rect, gap: 10)
        XCTAssertEqual(frames["a"], PaneRect(x: 0, y: 0, width: 495, height: 600))
        XCTAssertEqual(frames["b"], PaneRect(x: 505, y: 0, width: 495, height: 600))
        let rows = PaneNode.pane("a").splitting("a", with: "b", axis: .rows).frames(in: rect, gap: 10)
        XCTAssertEqual(rows["b"], PaneRect(x: 0, y: 305, width: 1000, height: 295))
    }

    func testDividersAndRatios() {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns).splitting("b", with: "c", axis: .rows)
        let dividers = layout.dividers(in: rect, gap: 10)
        XCTAssertEqual(dividers.map(\.path), [[], [1]])
        XCTAssertEqual(dividers[0].rect, PaneRect(x: 495, y: 0, width: 10, height: 600))
        XCTAssertEqual(dividers[1].axis, .rows)
        let wider = layout.settingRatio(0.7, at: [])
        XCTAssertEqual(wider.frames(in: rect, gap: 10)["a"]?.width, 693)
        XCTAssertEqual(layout.settingRatio(2, at: [1]).dividers(in: rect, gap: 10)[1].rect.minY,
                       (590 * 0.9).rounded())
    }

    func testNeighborFollowsTheLayout() {
        // a | b
        //   | c
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .columns).splitting("b", with: "c", axis: .rows)
        XCTAssertEqual(layout.neighbor(of: "a", .right, in: rect), "b")
        XCTAssertEqual(layout.neighbor(of: "c", .left, in: rect), "a")
        XCTAssertEqual(layout.neighbor(of: "b", .down, in: rect), "c")
        XCTAssertEqual(layout.neighbor(of: "c", .up, in: rect), "b")
        XCTAssertNil(layout.neighbor(of: "a", .left, in: rect))
        XCTAssertNil(layout.neighbor(of: "a", .down, in: rect))
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let layout = PaneNode.pane("a").splitting("a", with: "b", axis: .rows)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PaneNode.self, from: data), layout)
    }

    func testRegroupKeepsSavedTabsAndGivesTheRestTheirOwn() {
        let split = SavedPaneGroup(layout: PaneNode.pane("b").splitting("b", with: "c", axis: .columns), focused: "c")
        let groups = SavedPaneGroup.regroup(["a", "b", "c", "d"], saved: [split])
        XCTAssertEqual(groups.map(\.layout.panes), [["a"], ["b", "c"], ["d"]])
        XCTAssertEqual(groups[1].focused, "c")
    }

    func testRegroupWhenAFocusedPaneIsMissing() {
        let split = SavedPaneGroup(layout: PaneNode.pane("b").splitting("b", with: "c", axis: .columns), focused: "c")
        let groups = SavedPaneGroup.regroup(["b"], saved: [split])
        XCTAssertEqual(groups, [SavedPaneGroup(layout: .pane("b"), focused: "b")])
    }

    func testRegroupNeverPutsAPaneInTwoTabs() {
        let one = SavedPaneGroup(layout: PaneNode.pane("a").splitting("a", with: "b", axis: .columns), focused: "a")
        let two = SavedPaneGroup(layout: PaneNode.pane("b").splitting("b", with: "c", axis: .columns), focused: "b")
        let groups = SavedPaneGroup.regroup(["a", "b", "c"], saved: [one, two])
        XCTAssertEqual(groups.map(\.layout.panes), [["a", "b"], ["c"]])
        XCTAssertEqual(groups[1].focused, "c")
    }

    func testOldWorkspaceFilesHaveNoGroups() throws {
        let old = #"{"version":1,"savedAt":0,"selected":0,"tabs":[{"cwd":"/","scrollback":""}]}"#
        XCTAssertNil(try SavedWorkspace.decode(Data(old.utf8)).groups)
    }

    func testGroupsSurviveSaving() throws {
        let group = SavedPaneGroup(layout: PaneNode.pane("a").splitting("a", with: "b", axis: .columns), focused: "b")
        let workspace = SavedWorkspace(selected: 1, tabs: [SavedTab(cwd: "/", scrollback: "", resume: nil, tabID: "a"),
                                                           SavedTab(cwd: "/", scrollback: "", resume: nil, tabID: "b")],
                                       groups: [group])
        XCTAssertEqual(try SavedWorkspace.decode(workspace.encoded()).groups, [group])
    }
}

final class ModelNameTests: XCTestCase {
    func testClaudeIDs() {
        XCTAssertEqual(ModelName.short("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(ModelName.short("claude-sonnet-4-20250514"), "Sonnet 4")
        XCTAssertEqual(ModelName.short("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(ModelName.short("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.short("us.anthropic.claude-sonnet-4-5-20250929-v1:0"), "Sonnet 4.5")
        XCTAssertEqual(ModelName.short("claude-opus-4-1@20250805"), "Opus 4.1")
    }

    func testGPTIDs() {
        XCTAssertEqual(ModelName.short("gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(ModelName.short("gpt-5-codex"), "GPT-5 Codex")
        XCTAssertEqual(ModelName.short("gpt-5.1-codex-max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(ModelName.short("gpt-4o-mini"), "GPT-4o Mini")
        XCTAssertEqual(ModelName.short("gpt-5"), "GPT-5")
    }

    func testOtherModelsStayAsTheyAre() {
        XCTAssertEqual(ModelName.short("grok-4"), "grok-4")
        XCTAssertEqual(ModelName.short("o3"), "o3")
    }

    func testPlaceholders() {
        XCTAssertNil(ModelName.short("<synthetic>"))
        XCTAssertNil(ModelName.short(""))
    }
}
