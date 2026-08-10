import XCTest
@testable import FluxDL

final class NavigationTests: XCTestCase {
    func testAppTabEnumCount() {
        XCTAssertEqual(AppTab.allCases.count, 5, "FluxDL must have exactly 5 bottom tabs: Downloads, Browser, Proxy, Settings, Torrent.")
    }
    
    func testAppTabTitlesAndIcons() {
        let expectedTitles = ["Downloads", "Browser", "Proxy", "Settings", "Torrent"]
        let actualTitles = AppTab.allCases.map { $0.title }
        XCTAssertEqual(actualTitles, expectedTitles)
        
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.iconName.isEmpty)
        }
    }
    
    func testProxyTabReplacesHistory() {
        XCTAssertFalse(AppTab.allCases.contains { $0.title == "History" })
        XCTAssertTrue(AppTab.allCases.contains { $0.title == "Proxy" })
        XCTAssertEqual(AppTab.proxy.rawValue, 2, "Proxy must occupy the third tab slot (previously History).")
        XCTAssertEqual(AppTab.torrent.rawValue, 4, "Torrent tab position must remain unchanged.")
    }
}
