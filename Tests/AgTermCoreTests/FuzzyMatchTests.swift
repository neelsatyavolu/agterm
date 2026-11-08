import XCTest
@testable import AgTermCore

final class FuzzyMatchTests: XCTestCase {
    func testMatchesLettersInOrderIgnoringCaseAndSpaces() {
        XCTAssertNotNil(FuzzyMatch.match("spr", in: "Split Right"))
        XCTAssertNotNil(FuzzyMatch.match("split right", in: "Split Right"))
        XCTAssertNotNil(FuzzyMatch.match("SPLIT", in: "split down"))
        XCTAssertNil(FuzzyMatch.match("rs", in: "Split Right"))
        XCTAssertNil(FuzzyMatch.match("xyz", in: "Split Right"))
        XCTAssertNil(FuzzyMatch.match("tabs left", in: "New Tab"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.match("", in: "New Tab")?.positions, [])
        XCTAssertEqual(FuzzyMatch.match("  ", in: "New Tab")?.positions, [])
    }

    func testPositionsAreTheMatchedCharacters() {
        XCTAssertEqual(FuzzyMatch.match("nt", in: "New Tab")?.positions, [0, 4])
        XCTAssertEqual(FuzzyMatch.match("tab", in: "New Tab")?.positions, [4, 5, 6])
    }

    func testPrefersWordStartsOverLettersInsideWords() {
        // The "ri" that starts a word, not the one inside "Print".
        XCTAssertEqual(FuzzyMatch.match("ri", in: "Print Right")?.positions, [6, 7])
        XCTAssertEqual(FuzzyMatch.match("sd", in: "Split Down")?.positions, [0, 6])
    }

    func testRanksWordStartsAndRunsAboveScatteredLetters() {
        let titles = ["Select Previous Pane", "Split Right", "Show Previous Tab"]
        let ranked = FuzzyMatch.rank("split", titles) { $0 }.map(\.item)
        XCTAssertEqual(ranked.first, "Split Right")

        // A run from a word's start beats one letter from each of several words.
        let spl = FuzzyMatch.rank("spl", ["Select Pane Left", "Split Right"]) { $0 }.map(\.item)
        XCTAssertEqual(spl.first, "Split Right")

        let tabs = FuzzyMatch.rank("nt", ["Minimize", "New Tab", "Next Tab"]) { $0 }.map(\.item)
        XCTAssertEqual(tabs, ["New Tab", "Next Tab"])
    }

    func testPrefixBeatsLaterMatch() {
        let ranked = FuzzyMatch.rank("close", ["Quit and Close Everything", "Close Tab"]) { $0 }.map(\.item)
        XCTAssertEqual(ranked, ["Close Tab", "Quit and Close Everything"])
    }

    func testEmptyQueryKeepsOriginalOrder() {
        let items = ["b", "a", "c"]
        XCTAssertEqual(FuzzyMatch.rank("", items) { $0 }.map(\.item), items)
    }

    func testEqualScoresKeepOriginalOrder() {
        XCTAssertEqual(FuzzyMatch.rank("tab", ["Tab 2", "Tab 1"]) { $0 }.map(\.item), ["Tab 2", "Tab 1"])
    }

    func testIgnoresAccents() {
        XCTAssertEqual(FuzzyMatch.match("cafe", in: "Café Menu")?.positions, [0, 1, 2, 3])
        XCTAssertEqual(FuzzyMatch.match("é", in: "Cafe")?.positions, [3])
    }
}
