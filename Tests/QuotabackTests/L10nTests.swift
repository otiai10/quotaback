import XCTest
@testable import Quotaback

final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.apply(nil)
    }

    func testLanguageFromCode() {
        XCTAssertEqual(Language.from("ja"), .ja)
        XCTAssertEqual(Language.from("ja-JP"), .ja)
        XCTAssertEqual(Language.from("EN_us"), .en)
        XCTAssertNil(Language.from("fr"))
        XCTAssertNil(Language.from("jav"), "compared as a language code, not a prefix")
        XCTAssertNil(Language.from(nil))
    }

    func testApplySwitchesStringsAndFallsBackToSystem() {
        L10n.apply("en")
        XCTAssertEqual(L10n.refresh, "Refresh")
        L10n.apply("ja")
        XCTAssertEqual(L10n.refresh, "更新")
        L10n.apply("fr")
        XCTAssertEqual(L10n.refresh, "Refresh", "unsupported languages fall back to English")
        L10n.apply("ja")
        L10n.apply(nil)
        XCTAssertEqual(L10n.refresh, "Refresh", "English when unset")
    }

    func testConfigReadsLanguage() throws {
        let json = #"{"language": "ja", "refreshSeconds": 300, "accounts": []}"#
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).language, "ja")
        let none = #"{"refreshSeconds": 300, "accounts": []}"#
        XCTAssertNil(try JSONDecoder().decode(AppConfig.self, from: Data(none.utf8)).language)
    }
}
