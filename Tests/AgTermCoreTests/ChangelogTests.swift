import XCTest
@testable import AgTermCore

final class ChangelogTests: XCTestCase {
    private let sample = """
    # Changelog

    Intro text that is not part of any release.
    - Added: stray bullet before the first section

    ## 1.0.2 — 2026-10-25
    - Fixed: Settings toolbar fits.
    - Added: Shortcut can be changed.
    - Changed: Faster output.
    - Something unprefixed

    ## 1.0.1 — 2026-10-20
    - Added: Memory without agmux.

    ## 1.0.0 — 2026-10-01
    - Added: Remote.
    """

    func testParsesVersionsDatesAndKinds() {
        let releases = Changelog.parse(sample)
        XCTAssertEqual(releases.map(\.version), ["1.0.2", "1.0.1", "1.0.0"])
        XCTAssertEqual(releases[0].date, "2026-10-25")
        XCTAssertEqual(releases[0].items, [
            Item(kind: .fixed, text: "Settings toolbar fits."),
            Item(kind: .added, text: "Shortcut can be changed."),
            Item(kind: .changed, text: "Faster output."),
            Item(kind: .other, text: "Something unprefixed"),
        ])
    }

    func testHeadingWithHyphenOrNoDate() {
        let releases = Changelog.parse("## 1.0.3 - 2026-11-01\n- Added: a.\n## 1.0.2\n- Fixed: b.")
        XCTAssertEqual(releases.map(\.version), ["1.0.3", "1.0.2"])
        XCTAssertEqual(releases[0].date, "2026-11-01")
        XCTAssertNil(releases[1].date)
    }

    func testUnseenSpansSkippedVersions() {
        let releases = Changelog.parse(sample)
        let unseen = Changelog.unseen(releases, lastSeen: "1.0.0", current: "1.0.2")
        XCTAssertEqual(unseen.map(\.version), ["1.0.2", "1.0.1"])
    }

    func testFirstInstallShowsNothing() {
        let releases = Changelog.parse(sample)
        XCTAssertEqual(Changelog.unseen(releases, lastSeen: nil, current: "1.0.2"), [])
    }

    func testVersionsCompareNumerically() {
        XCTAssertEqual(Changelog.compare("1.0.10", "1.0.9"), .orderedDescending)
        XCTAssertEqual(Changelog.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(Changelog.compare("0.9.9", "1.0"), .orderedAscending)
    }

    func testBetaSections() {
        let releases = Changelog.parse("""
        ## 1.1.0 — 2026-11-20
        - Added: Cloud.
        ## 1.1.0-beta.2 — 2026-11-10
        - Fixed: b.
        ## 1.1.0-beta.1 — 2026-10-30
        - Added: Cloud (beta).
        ## 1.0.9 — 2026-10-30
        - Fixed: a.
        """)
        XCTAssertEqual(releases.map(\.version), ["1.1.0", "1.1.0-beta.2", "1.1.0-beta.1", "1.0.9"])
        XCTAssertEqual(releases[2].date, "2026-10-30")
        XCTAssertEqual(Changelog.compare("1.1.0-beta.1", "1.1.0"), .orderedAscending)
        XCTAssertEqual(Changelog.compare("1.1.0-beta.2", "1.1.0-beta.1"), .orderedDescending)
        XCTAssertEqual(Changelog.compare("1.1.0-beta.1", "1.0.9"), .orderedDescending)
        // A tester moving between betas, then to the release, sees each step once.
        XCTAssertEqual(Changelog.unseen(releases, lastSeen: "1.1.0-beta.1", current: "1.1.0-beta.2").map(\.version), ["1.1.0-beta.2"])
        XCTAssertEqual(Changelog.unseen(releases, lastSeen: "1.1.0-beta.2", current: "1.1.0").map(\.version), ["1.1.0"])
        // A stable user never sees beta sections; the release's section repeats their changes.
        XCTAssertEqual(Changelog.unseen(releases, lastSeen: "1.0.9", current: "1.1.0").map(\.version), ["1.1.0"])
        XCTAssertEqual(Changelog.shown(releases, current: "1.1.0").map(\.version), ["1.1.0", "1.0.9"])
        XCTAssertEqual(Changelog.shown(releases, current: "1.1.0-beta.2").count, 4)
        XCTAssertEqual(Changelog.effectiveLastSeen(stored: nil, previousInstall: true, releases: releases, current: "1.1.0"), "1.0.9")
    }

    func testIgnoresTextOutsideSections() {
        let releases = Changelog.parse(sample)
        XCTAssertEqual(releases.flatMap(\.items).filter { $0.text.contains("stray") }.count, 0)
        XCTAssertEqual(Changelog.parse("just words\n- Added: nothing"), [])
    }

    func testEffectiveLastSeen() {
        let releases = Changelog.parse(sample)
        XCTAssertEqual(Changelog.effectiveLastSeen(stored: "1.0.0", previousInstall: true, releases: releases, current: "1.0.2"), "1.0.0")
        XCTAssertNil(Changelog.effectiveLastSeen(stored: nil, previousInstall: false, releases: releases, current: "1.0.2"))
        XCTAssertEqual(Changelog.effectiveLastSeen(stored: nil, previousInstall: true, releases: releases, current: "1.0.2"), "1.0.1")
        XCTAssertNil(Changelog.effectiveLastSeen(stored: nil, previousInstall: true, releases: releases, current: "1.0.0"))
    }
}
