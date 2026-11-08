import CoreGraphics
import CoreLocation
import XCTest
@testable import SmartAuto

/// The dash screen draws where the layout says and still encodes to what the 368G plays.
final class DashRendererTests: XCTestCase {
    func testDashboardDrawsCardsAndText() throws {
        let encoder = try XCTUnwrap(SoftwareVideoEncoder(width: 1280, height: 528, bitRate: 1_800_000, frameRate: 12))
        let context = try XCTUnwrap(encoder.makeContext())
        let renderer = DashRenderer(size: CGSize(width: 1280, height: 528))
        var scene = DashScene()
        scene.vehicle = DashScene.Vehicle(connected: true, locked: true, voltage: 12.6)
        renderer.draw(scene, in: context)

        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * context.bytesPerRow + x * 4 // X, R, G, B; row 0 is the top
            return (Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }
        XCTAssertEqual(rgb(4, 4).0, 0, "outside the cards is black")
        let card = rgb(880, 40)
        XCTAssertTrue((24...32).contains(card.0) && (24...34).contains(card.2), "clock card is #1C1C1E, got \(card)")

        var bright = 0
        for y in 40 ..< 250 { for x in 870 ..< 1250 where rgb(x, y).0 > 200 { bright += 1 } }
        XCTAssertGreaterThan(bright, 500, "the clock is drawn")

        let frame = try XCTUnwrap(encoder.encode(context, keyFrame: true))
        XCTAssertEqual(H264NAL.headers(inAnnexB: frame), [0x67, 0x68, 0x65])
    }

    func testGuidanceDrawsRouteAndTurnCard() throws {
        let encoder = try XCTUnwrap(SoftwareVideoEncoder(width: 1280, height: 528, bitRate: 3_000_000, frameRate: 20))
        let context = try XCTUnwrap(encoder.makeContext())
        let renderer = DashRenderer(size: CGSize(width: 1280, height: 528))
        let here = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        var scene = DashScene()
        scene.position = here
        scene.course = 0 // facing north: the route ahead goes straight up the screen
        scene.navigation = DashScene.Navigation(
            maneuver: .right, distanceToManeuver: 350, instruction: "เลี้ยวขวาเข้าสู่ ถนนทดสอบ",
            arrival: Date().addingTimeInterval(600), remainingDistance: 4200, remainingTime: 600,
            upcoming: [here, CLLocationCoordinate2D(latitude: 13.003, longitude: 100.0)],
            status: .guiding, destinationName: "ทดสอบ")
        renderer.draw(scene, in: context)

        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * context.bytesPerRow + x * 4
            return (Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }
        let route = rgb(760, 200) // above the puck, on the line ahead
        XCTAssertGreaterThan(route.2, 200, "the route is blue, got \(route)")
        XCTAssertLessThan(route.0, 60)
        let card = rgb(30, 30)
        XCTAssertTrue((20...36).contains(card.0), "turn card is drawn, got \(card)")

        XCTAssertEqual(H264NAL.headers(inAnnexB: try XCTUnwrap(encoder.encode(context, keyFrame: true))), [0x67, 0x68, 0x65])
    }

    func testThreeDGuidanceTiltsTheRouteAhead() throws {
        let encoder = try XCTUnwrap(SoftwareVideoEncoder(width: 1280, height: 528, bitRate: 3_000_000, frameRate: 20))
        let context = try XCTUnwrap(encoder.makeContext())
        let renderer = DashRenderer(size: CGSize(width: 1280, height: 528))
        let here = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        var scene = DashScene()
        scene.position = here
        scene.course = 0
        scene.threeD = true
        scene.navigation = DashScene.Navigation(
            maneuver: .left, distanceToManeuver: 70, instruction: "เลี้ยวซ้าย", arrival: nil,
            remainingDistance: 400, remainingTime: 60,
            upcoming: [here, CLLocationCoordinate2D(latitude: 13.003, longitude: 100.0)],
            status: .guiding, destinationName: "ทดสอบ")
        renderer.draw(scene, in: context)

        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * context.bytesPerRow + x * 4
            return (Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }
        let ahead = rgb(640, 300)
        XCTAssertGreaterThan(ahead.2, 200, "the route ahead is blue in 3D, got \(ahead)")
        let beside = rgb(1000, 300)
        XCTAssertLessThan(beside.2, 60, "beside the route is the empty map, got \(beside)")

        let bands = Perspective.bands(height: 528, width: 1280)
        XCTAssertLessThan(bands.first!.source.width, CGFloat(Perspective.planarWidth) + 1)
        XCTAssertGreaterThan(bands.first!.source.width, bands.last!.source.width * 1.5, "far bands cover more ground")
    }

    func testBatterySymbolFollowsVoltage() {
        XCTAssertEqual(DashRenderer.batterySymbol(12.7), "battery.100")
        XCTAssertEqual(DashRenderer.batterySymbol(12.1), "battery.75")
        XCTAssertEqual(DashRenderer.batterySymbol(11.7), "battery.50")
        XCTAssertEqual(DashRenderer.batterySymbol(11.2), "battery.25")
    }
}
