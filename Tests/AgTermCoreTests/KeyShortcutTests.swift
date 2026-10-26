import XCTest
@testable import AgTermCore

final class KeyShortcutTests: XCTestCase {
    func testDisplayUsesTheMacModifierOrder() {
        XCTAssertEqual(KeyShortcut.newAgentTabDefault.display, "⌥⌘T")
        XCTAssertEqual(KeyShortcut(key: "n", modifiers: [.command, .shift, .control, .option]).display, "⌃⌥⇧⌘N")
        XCTAssertEqual(KeyShortcut(key: "/", modifiers: [.control]).display, "⌃/")
    }

    func testOnlyCommandOrControlChordsWithAPrintableKeyAreUsable() {
        XCTAssertTrue(KeyShortcut(key: "t", modifiers: [.command, .option]).isUsable)
        XCTAssertTrue(KeyShortcut(key: "a", modifiers: [.control]).isUsable)
        // Would swallow ordinary typing in the terminal.
        XCTAssertFalse(KeyShortcut(key: "t", modifiers: [.option]).isUsable)
        XCTAssertFalse(KeyShortcut(key: "t", modifiers: [.shift]).isUsable)
        XCTAssertFalse(KeyShortcut(key: "\t", modifiers: [.command]).isUsable)
        XCTAssertFalse(KeyShortcut(key: " ", modifiers: [.command]).isUsable)
        XCTAssertFalse(KeyShortcut(key: "tt", modifiers: [.command]).isUsable)
    }

    func testKeysAreStoredLowercase() {
        XCTAssertEqual(KeyShortcut(key: "T", modifiers: [.command]).key, "t")
    }

    func testSavedShortcutLoadsBack() {
        let defaults = UserDefaults(suiteName: "KeyShortcutTests.\(UUID())")!
        let shortcut = KeyShortcut(key: "j", modifiers: [.command, .shift])
        shortcut.save(to: defaults, key: "s")
        XCTAssertEqual(KeyShortcut.load(from: defaults, key: "s", fallback: .newAgentTabDefault), shortcut)
    }

    func testMissingOrBadValueFallsBack() {
        let defaults = UserDefaults(suiteName: "KeyShortcutTests.\(UUID())")!
        XCTAssertEqual(KeyShortcut.load(from: defaults, key: "s", fallback: .newAgentTabDefault), .newAgentTabDefault)
        defaults.set("garbage", forKey: "s")
        XCTAssertEqual(KeyShortcut.load(from: defaults, key: "s", fallback: .newAgentTabDefault), .newAgentTabDefault)
        // Saved, then made unusable by a hand edit.
        defaults.set(["key": "t", "modifiers": 0] as [String: Any], forKey: "s")
        XCTAssertEqual(KeyShortcut.load(from: defaults, key: "s", fallback: .newAgentTabDefault), .newAgentTabDefault)
    }
}
