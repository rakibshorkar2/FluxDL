import XCTest
@testable import FluxDL

final class NavigationTests: XCTestCase {
    func testAppTabEnumCount() {
        XCTAssertEqual(AppTab.allCases.count, 4, "FluxDL must have exactly 4 bottom tabs per PRD spec.")
    }
    
    func testAppTabTitlesAndIcons() {
        let expectedTitles = ["Downloads", "Browser", "History", "Settings"]
        let actualTitles = AppTab.allCases.map { $0.title }
        XCTAssertEqual(actualTitles, expectedTitles)
        
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.iconName.isEmpty)
        }
    }
}
