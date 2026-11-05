import XCTest
@testable import AgTermCore

final class ChatMarkdownTests: XCTestCase {
    /// The reply from the beta report: a table between two paragraphs.
    func testSplitsTableFromSurroundingText() {
        let text = """
        All four changes are pushed:

        | Commit | Change |
        |---|---|
        | 1936d6d | Alaska's boroughs now show on the county map. |
        | 5dfecfc | Called toss-ups stay pinned. |

        I committed only my own changes.
        """
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .text("All four changes are pushed:"),
            .table(ChatMarkdown.Table(
                header: ["Commit", "Change"],
                alignments: [.leading, .leading],
                rows: [["1936d6d", "Alaska's boroughs now show on the county map."],
                       ["5dfecfc", "Called toss-ups stay pinned."]])),
            .text("I committed only my own changes."),
        ])
    }

    func testPlainTextIsOneBlock() {
        XCTAssertEqual(ChatMarkdown.blocks("a | b\nno delimiter row"), [.text("a | b\nno delimiter row")])
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
    }

    func testAlignmentsAndOuterPipesOptional() {
        let table = ChatMarkdown.blocks("Name | Count | Mid\n:--- | ---: | :-:\nx | 3 | y")
        XCTAssertEqual(table, [.table(ChatMarkdown.Table(
            header: ["Name", "Count", "Mid"],
            alignments: [.leading, .trailing, .center],
            rows: [["x", "3", "y"]]))])
    }

    func testRowsPaddedOrCutToHeaderWidth() {
        let blocks = ChatMarkdown.blocks("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        XCTAssertEqual(blocks, [.table(ChatMarkdown.Table(
            header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", ""], ["1", "2"]]))])
    }

    func testEscapedPipeStaysInCell() {
        let blocks = ChatMarkdown.blocks("| cmd |\n|---|\n| `a \\| b` |")
        XCTAssertEqual(blocks, [.table(ChatMarkdown.Table(
            header: ["cmd"], alignments: [.leading], rows: [["`a | b`"]]))])
    }

    func testDelimiterWithWrongColumnCountIsNotATable() {
        let text = "| a | b |\n|---|"
        XCTAssertEqual(ChatMarkdown.blocks(text), [.text(text)])
    }

    func testTableEndsAtBlankOrPipelessLine() {
        let blocks = ChatMarkdown.blocks("| a |\n|---|\n| 1 |\nafter")
        XCTAssertEqual(blocks, [
            .table(ChatMarkdown.Table(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .text("after"),
        ])
    }

    func testTablesInsideCodeFencesStayText() {
        let text = "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```"
        XCTAssertEqual(ChatMarkdown.blocks(text), [.text(text)])
    }
}
