import XCTest
@testable import AgTermCore

final class ThemeCatalogTests: XCTestCase {
    func testEveryThemeIsComplete() {
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)).count, ThemeCatalog.all.count, "ids must be unique")
        for theme in ThemeCatalog.all {
            XCTAssertEqual(theme.ansi.count, 16, theme.id)
        }
    }

    func testTextIsReadableOnEveryTheme() {
        for theme in ThemeCatalog.all {
            XCTAssertGreaterThanOrEqual(theme.fg.contrast(with: theme.bg), 7, "\(theme.id) body text")
            XCTAssertGreaterThanOrEqual(theme.accent.contrast(with: theme.bg), 3, "\(theme.id) accent")
        }
    }

    func testUnknownIdFallsBackToDefault() {
        XCTAssertEqual(ThemeCatalog.named("nope").id, ThemeCatalog.defaultID)
        XCTAssertEqual(ThemeCatalog.named("paper").id, "paper")
    }

    func testChromeSitsBetweenBackgroundAndText() {
        let ink = ThemeCatalog.named("ink")
        XCTAssertGreaterThan(ink.chrome.luminance, ink.bg.luminance)
        let paper = ThemeCatalog.named("paper")
        XCTAssertLessThan(paper.chrome.luminance, paper.bg.luminance)
    }
}

final class AppearanceSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "agterm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsWhenNothingSaved() {
        let s = AppearanceSettings.load(from: freshDefaults())
        XCTAssertEqual(s, AppearanceSettings())
        XCTAssertEqual(s.themeID, "ink")
        XCTAssertNil(s.fontFamily)
        XCTAssertEqual(s.opacity, 1)
    }

    func testRoundTrip() {
        let defaults = freshDefaults()
        let s = AppearanceSettings(themeID: "paper", fontFamily: "Menlo", fontSize: 15, opacity: 0.8, blur: 0.3)
        s.save(to: defaults)
        XCTAssertEqual(AppearanceSettings.load(from: defaults), s)
    }

    func testOutOfRangeValuesAreClamped() {
        let s = AppearanceSettings(themeID: "ink", fontFamily: nil, fontSize: 200, opacity: 0.01, blur: 7)
        XCTAssertEqual(s.fontSize, AppearanceSettings.fontSizeRange.upperBound)
        XCTAssertEqual(s.opacity, AppearanceSettings.opacityRange.lowerBound)
        XCTAssertEqual(s.blur, 1)
    }

    func testCorruptStoredValuesFallBack() {
        let defaults = freshDefaults()
        defaults.set("not a number", forKey: "fontSize")
        defaults.set(-4, forKey: "opacity")
        let s = AppearanceSettings.load(from: defaults)
        XCTAssertEqual(s.fontSize, AppearanceSettings().fontSize)
        XCTAssertEqual(s.opacity, AppearanceSettings.opacityRange.lowerBound)
    }
}

final class DiskAccessTests: XCTestCase {
    func testAnyReadableProbeMeansGranted() {
        XCTAssertEqual(DiskAccess.decide([EPERM, 0, ENOENT]), .granted)
    }

    func testPermissionDeniedMeansMissing() {
        XCTAssertEqual(DiskAccess.decide([ENOENT, EPERM]), .denied)
        XCTAssertEqual(DiskAccess.decide([EACCES]), .denied)
    }

    func testNothingConclusiveIsUnknown() {
        XCTAssertEqual(DiskAccess.decide([ENOENT, ENOENT]), .unknown)
        XCTAssertEqual(DiskAccess.decide([]), .unknown)
    }
}
