import XCTest

final class LocaleHelperTests: XCTestCase {
    private let installed: Set<String> = [
        "en_AU.UTF-8", "en_GB.UTF-8", "en_US.UTF-8", "fr_BE.UTF-8", "fr_CA.UTF-8", "fr_FR.UTF-8",
        "de_AT.UTF-8", "de_DE.UTF-8", "zh_CN.UTF-8", "zh_HK.UTF-8", "zh_TW.UTF-8", "pt_BR.UTF-8",
        "sr_RS.UTF-8", "sr_RS.UTF-8@latin",
    ]

    private func posix(_ tag: String) -> String? {
        LocaleHelper.posixLocale(for: tag, installed: installed)
    }

    func testInstalledPairIsKept() {
        XCTAssertEqual(posix("en-GB"), "en_GB.UTF-8")
        XCTAssertEqual(posix("fr-CA"), "fr_CA.UTF-8")
        XCTAssertEqual(posix("zh-Hant-HK"), "zh_HK.UTF-8")
    }

    func testUninstalledPairUsesLikelyRegion() {
        XCTAssertEqual(posix("fr-US"), "fr_FR.UTF-8")
        XCTAssertEqual(posix("en-MX"), "en_US.UTF-8")
        XCTAssertEqual(posix("de-US"), "de_DE.UTF-8")
        XCTAssertEqual(posix("en"), "en_US.UTF-8")
    }

    func testScriptPicksRegion() {
        XCTAssertEqual(posix("zh-Hant-US"), "zh_TW.UTF-8")
        XCTAssertEqual(posix("zh-Hans-US"), "zh_CN.UTF-8")
        XCTAssertEqual(posix("zh-Hant-CN"), "zh_TW.UTF-8")
        XCTAssertEqual(posix("zh-Hans-TW"), "zh_CN.UTF-8")
    }

    func testScriptModifier() {
        XCTAssertEqual(posix("sr-Latn-RS"), "sr_RS.UTF-8@latin")
        XCTAssertEqual(posix("sr-Latn"), "sr_RS.UTF-8@latin")
        XCTAssertEqual(posix("sr-Cyrl-RS"), "sr_RS.UTF-8")
        XCTAssertEqual(posix("sr-RS"), "sr_RS.UTF-8")
    }

    func testUnknownLanguageIsNil() {
        XCTAssertNil(posix("cy-GB"))
        XCTAssertNil(posix(""))
    }
}
