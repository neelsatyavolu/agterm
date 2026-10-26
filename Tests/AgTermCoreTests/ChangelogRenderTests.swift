import XCTest
@testable import AgTermCore

final class ChangelogRenderTests: XCTestCase {
    private let releases = [
        Release(version: "1.0.2", date: "2026-10-20", items: [
            Item(kind: .added, text: "A new What's New tab plays the changelog in a terminal after an update."),
            Item(kind: .changed, text: "Settings toolbar is tighter."),
            Item(kind: .fixed, text: "Themes apply right away."),
            Item(kind: .other, text: "Supercalifragilisticexpialidocious_and_then_some_more_letters"),
        ]),
        Release(version: "1.0.1", date: nil, items: [Item(kind: .fixed, text: "Small fix.")]),
    ]

    func testHeaderFitsWidth() {
        for columns in [20, 40, 78, 120] {
            let lines = ChangelogRender.lines(releases, columns: columns)
            XCTAssertFalse(lines.isEmpty)
            for line in lines {
                XCTAssertLessThanOrEqual(ChangelogRender.visibleWidth(line), columns, line)
            }
        }
        let wide = ChangelogRender.lines(releases, columns: 120)
        XCTAssertEqual(ChangelogRender.visibleWidth(wide[0]), 78)
        XCTAssertTrue(ChangelogRender.stripSGR(wide[0]).hasPrefix("╭─ agterm · what's new ─"))
        XCTAssertTrue(ChangelogRender.stripSGR(wide[0]).hasSuffix("╮"))
        XCTAssertTrue(wide.contains { ChangelogRender.stripSGR($0).hasPrefix("╰") })
    }

    func testWrapsWithHangingIndent() {
        let lines = ChangelogRender.lines(releases, columns: 40).map(ChangelogRender.stripSGR)
        let start = lines.firstIndex { $0.hasPrefix("  + ") }!
        XCTAssertTrue(lines[start + 1].hasPrefix("    "))
        XCTAssertFalse(lines[start + 1].hasPrefix("     "))
        XCTAssertTrue(lines[start + 1].trimmingCharacters(in: .whitespaces).count > 0)
        // long word is hard-split, continuation keeps the indent
        let at = lines.firstIndex { $0.hasPrefix("  · Supercal") }!
        XCTAssertTrue(lines[at + 1].hasPrefix("    ") && lines[at + 1].hasSuffix("letters"))
    }

    func testKindsGetTheirMarkers() {
        let lines = ChangelogRender.lines(releases, columns: 78)
        let plain = lines.map(ChangelogRender.stripSGR)
        XCTAssertTrue(plain.contains { $0.hasPrefix("  + A new") })
        XCTAssertTrue(plain.contains { $0.hasPrefix("  ~ Settings") })
        XCTAssertTrue(plain.contains { $0.hasPrefix("  ✓ Themes") })
        XCTAssertTrue(plain.contains { $0.hasPrefix("  · Supercal") })
        XCTAssertTrue(plain.contains { $0.contains("v1.0.2") && $0.contains("2026-10-20") })
        XCTAssertEqual(plain.last, "  full history: github.com/neelsatyavolu/agterm/releases")
        let all = lines.joined()
        XCTAssertFalse(all.contains("38;"))
        XCTAssertFalse(all.contains("48;"))
        XCTAssertTrue(lines.first { $0.contains("A new") }!.contains("\u{1B}[32m"))
    }
}
