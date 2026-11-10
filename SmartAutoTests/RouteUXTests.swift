import XCTest
@testable import SmartAuto

final class RouteUXTests: XCTestCase {
    func testLandscapePreviewReservesSpaceForRouteListAndGoButton() {
        let height: CGFloat = 300
        let map = RoutePreviewLayout.mapHeight(availableHeight: height, landscape: true, accessibilityText: false)
        XCTAssertGreaterThan(map, 0)
        XCTAssertLessThanOrEqual(map, 150)
        XCTAssertGreaterThanOrEqual(height - map, 180)
    }

    func testShortAccessibilitySheetPrioritizesRouteControlsOverMap() {
        XCTAssertEqual(RoutePreviewLayout.mapHeight(availableHeight: 300, landscape: true, accessibilityText: true), 0)
    }

    func testTallPortraitKeepsMapBoundedAndLeavesRoomForStops() {
        let height: CGFloat = 800
        let map = RoutePreviewLayout.mapHeight(availableHeight: height, landscape: false, accessibilityText: false)
        XCTAssertEqual(map, 280)
        XCTAssertGreaterThanOrEqual(height - map, 180)
    }
}
