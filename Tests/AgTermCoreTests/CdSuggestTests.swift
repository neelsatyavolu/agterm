import XCTest
@testable import AgTermCore

final class CdSuggestTests: XCTestCase {
    func testQueryIsTheWordAfterCd() {
        XCTAssertEqual(CdSuggest.query(beforeCursor: "neel@mac ~ % cd sheaf"), "sheaf")
        XCTAssertEqual(CdSuggest.query(beforeCursor: "~ ❯ git pull && cd agt"), "agt")
        XCTAssertEqual(CdSuggest.query(beforeCursor: "$ cd   sheaf"), "sheaf")
    }

    func testNoQueryForOtherCommandsPathsAndEmptyWords() {
        XCTAssertNil(CdSuggest.query(beforeCursor: "% ls sheaf"))
        XCTAssertNil(CdSuggest.query(beforeCursor: "% abcd sheaf"))
        XCTAssertNil(CdSuggest.query(beforeCursor: "% cd "))
        XCTAssertNil(CdSuggest.query(beforeCursor: "% cd sheaf other"))
        // Paths are left to the shell's own tab completion.
        XCTAssertNil(CdSuggest.query(beforeCursor: "% cd ~/Doc"))
        XCTAssertNil(CdSuggest.query(beforeCursor: "% cd ../x"))
        XCTAssertNil(CdSuggest.query(beforeCursor: "% cd -"))
    }

    func testRankingPrefersExactThenPrefixThenContainsThenFuzzy() {
        let dirs = ["/h/a/xsheafnotes", "/h/b/sheafnote-old", "/h/c/sheafnote", "/h/d/s-h-e-a-f", "/h/e/other"]
        XCTAssertEqual(CdSuggest.rank(query: "sheafnote", cwd: "/h", candidates: dirs, visits: [:]),
                       ["/h/c/sheafnote", "/h/b/sheafnote-old", "/h/a/xsheafnotes"])
        XCTAssertEqual(CdSuggest.rank(query: "shf", cwd: "/h", candidates: dirs, visits: [:]),
                       ["/h/a/xsheafnotes", "/h/b/sheafnote-old", "/h/c/sheafnote", "/h/d/s-h-e-a-f"])
    }

    func testLooseMatchesOnlyWhenNothingContainsTheWord() {
        let dirs = ["/h/GitHub/agterm", "/h/skills/django-patterns"]
        XCTAssertEqual(CdSuggest.rank(query: "agter", cwd: "/h", candidates: dirs, visits: [:]), ["/h/GitHub/agterm"])
        XCTAssertEqual(CdSuggest.rank(query: "dpat", cwd: "/h", candidates: dirs, visits: [:]), ["/h/skills/django-patterns"])
    }

    func testTiesGoToCwdChildrenThenVisitsThenShallowerPaths() {
        let dirs = ["/h/deep/down/app", "/h/x/app", "/h/y/app", "/h/here/app"]
        XCTAssertEqual(CdSuggest.rank(query: "app", cwd: "/h/here", candidates: dirs, visits: ["/h/y/app": 3]),
                       ["/h/here/app", "/h/y/app", "/h/x/app", "/h/deep/down/app"])
    }

    func testRankIsCaseInsensitiveSkipsCwdAndDuplicatesAndLimits() {
        let dirs = ["/h/Sheaf", "/h/Sheaf", "/h/sheaf2", "/h"] + (0..<20).map { "/h/z/sheaf\($0)" }
        let ranked = CdSuggest.rank(query: "SHEAF", cwd: "/h/Sheaf", candidates: dirs, visits: [:])
        XCTAssertEqual(ranked.count, CdSuggest.limit)
        XCTAssertFalse(ranked.contains("/h/Sheaf"))
        XCTAssertEqual(ranked.first, "/h/sheaf2")
    }

    func testDisplayAbbreviatesHomeAndEscapes() {
        XCTAssertEqual(CdSuggest.display("/Users/n/Documents/GitHub/sheafnote", home: "/Users/n"), "~/Documents/GitHub/sheafnote")
        XCTAssertEqual(CdSuggest.display("/Users/n/My Stuff/it's (1)", home: "/Users/n"), #"~/My\ Stuff/it\'s\ \(1\)"#)
        XCTAssertEqual(CdSuggest.display("/Users/n", home: "/Users/n"), "~")
        XCTAssertEqual(CdSuggest.display("/Users/nx", home: "/Users/n"), "/Users/nx")
    }

    func testKeystrokesEraseTheWordThenTypeThePath() {
        XCTAssertEqual(CdSuggest.keystrokes(replacing: "shé", with: "~/a"), [0x7F, 0x7F, 0x7F] + Array("~/a".utf8))
    }
}
