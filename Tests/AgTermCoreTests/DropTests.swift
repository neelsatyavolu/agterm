import XCTest
@testable import AgTermCore

final class ShellEscapeTests: XCTestCase {
    func testPlainPathIsUnchanged() {
        XCTAssertEqual(ShellEscape.path("/Users/sam/code/app.ts"), "/Users/sam/code/app.ts")
    }

    func testSpacesAndShellCharactersAreBackslashed() {
        XCTAssertEqual(ShellEscape.path("/Users/sam/My Shots/a (1).png"), #"/Users/sam/My\ Shots/a\ \(1\).png"#)
        XCTAssertEqual(ShellEscape.path("it's $HOME & more;"), #"it\'s\ \$HOME\ \&\ more\;"#)
        XCTAssertEqual(ShellEscape.path("glob*?[x]{y}|<>`!#~=\"\\"), ##"glob\*\?\[x\]\{y\}\|\<\>\`\!\#\~\=\"\\"##)
    }

    func testUnicodeIsKept() {
        XCTAssertEqual(ShellEscape.path("/tmp/naïve 日本.txt"), #"/tmp/naïve\ 日本.txt"#)
    }

    func testDropTextJoinsPathsWithTrailingSpace() {
        XCTAssertEqual(DropText.forPaths(["/a b", "/c"]), #"/a\ b /c "#)
        XCTAssertEqual(DropText.forPaths([]), "")
    }

    func testBracketedPasteWrapsText() {
        XCTAssertEqual(DropText.wrap("/a ", bracketed: true), "\u{1b}[200~/a \u{1b}[201~")
        XCTAssertEqual(DropText.wrap("/a ", bracketed: false), "/a ")
    }
}

final class BlurTests: XCTestCase {
    func testNoBlurWhenSolidOrZero() {
        XCTAssertEqual(WindowBlur.radius(opacity: 1, blur: 1), 0)
        XCTAssertEqual(WindowBlur.radius(opacity: 0.6, blur: 0), 0)
    }

    func testRadiusGrowsWithBlurAndTransparency() {
        let light = WindowBlur.radius(opacity: 0.9, blur: 0.5)
        let clear = WindowBlur.radius(opacity: 0.4, blur: 0.5)
        XCTAssertGreaterThan(light, 0)
        XCTAssertGreaterThan(clear, light, "more see-through windows need more blur to keep text behind unreadable")
        XCTAssertLessThanOrEqual(WindowBlur.radius(opacity: 0.3, blur: 1), WindowBlur.maxRadius)
    }

    func testFullScreenIsSolid() {
        XCTAssertEqual(WindowBlur.effectiveOpacity(0.5, fullScreen: true), 1)
        XCTAssertEqual(WindowBlur.effectiveOpacity(0.5, fullScreen: false), 0.5)
    }

    func testLegacyBoolBlurSettingMigrates() {
        let name = "agterm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "blur")
        XCTAssertEqual(AppearanceSettings.load(from: defaults).blur, 1)
        // The old toggle's "off" only meant it was never switched on, so it gets the new default.
        defaults.set(false, forKey: "blur")
        XCTAssertEqual(AppearanceSettings.load(from: defaults).blur, AppearanceSettings().blur)
        var off = AppearanceSettings()
        off.blur = 0
        off.save(to: defaults)
        XCTAssertEqual(AppearanceSettings.load(from: defaults).blur, 0, "a slider set to Off stays off")
        defaults.removePersistentDomain(forName: name)
    }
}
