import CoreLocation
import MapKit
import XCTest
@testable import SmartAuto

final class DashNavigationTests: XCTestCase {
    // East about 1.08 km, then north about 1.1 km.
    private let start = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
    private let corner = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.01)
    private let end = CLLocationCoordinate2D(latitude: 13.01, longitude: 100.01)

    private func route() -> DashRoute {
        let first = DashRoute.meters(start, corner)
        let second = DashRoute.meters(corner, end)
        return DashRoute(coordinates: [start, corner, end],
                         steps: [("", first), ("เลี้ยวซ้ายเข้าสู่ ถนนทดสอบ", second), ("ถึงจุดหมาย", 0)],
                         expectedTravelTime: 300)
    }

    func testTurnArrowsComeFromTheGeometry() {
        let steps = route().steps
        XCTAssertEqual(steps.map(\.maneuver), [.straight, .left, .arrive])
        XCTAssertEqual(steps[1].startDistance, DashRoute.meters(start, corner), accuracy: 1)
    }

    func testStepPositionsUseRouteGeometryInsteadOfReportedDistances() {
        let cornerDistance = DashRoute.meters(start, corner)
        let total = cornerDistance + DashRoute.meters(corner, end)
        let route = DashRoute(coordinates: [start, corner, end],
                              steps: [("", cornerDistance + 150), ("Turn left", 300)],
                              expectedTravelTime: 300, stepStarts: [0, cornerDistance])
        XCTAssertEqual(route.steps[1].startDistance, cornerDistance, accuracy: 1)
        XCTAssertEqual(route.steps[1].maneuver, .left)
        XCTAssertEqual(route.steps.last?.maneuver, .arrive)
        XCTAssertEqual(route.steps.last!.startDistance, total, accuracy: 1)
        XCTAssertEqual(route.progress(at: start, hint: nil).nextStep, 1)
        XCTAssertEqual(route.progress(at: corner, hint: nil).nextStep, 2)
    }

    func testManeuverClassification() {
        XCTAssertEqual(DashManeuver.from(turn: 5, instruction: "", isLast: false), .straight)
        XCTAssertEqual(DashManeuver.from(turn: 30, instruction: "", isLast: false), .slightRight)
        XCTAssertEqual(DashManeuver.from(turn: -90, instruction: "", isLast: false), .left)
        XCTAssertEqual(DashManeuver.from(turn: 150, instruction: "", isLast: false), .sharpRight)
        XCTAssertEqual(DashManeuver.from(turn: 178, instruction: "", isLast: false), .uTurnRight)
        XCTAssertEqual(DashManeuver.from(turn: 90, instruction: "ที่วงเวียน ใช้ทางออกที่ 2", isLast: false), .roundabout)
        XCTAssertEqual(DashManeuver.from(turn: 90, instruction: "", isLast: true), .arrive)
    }

    func testCoordinateLookupHandlesDuplicatePointsAndRouteEnds() {
        let route = DashRoute(coordinates: [start, start, corner, end], steps: [], expectedTravelTime: 300)
        let atStart = route.coordinate(at: 0)
        let atCorner = route.coordinate(at: route.cumulative[2])
        let afterEnd = route.coordinate(at: route.distance + 100)
        XCTAssertEqual(DashRoute.meters(atStart, start), 0, accuracy: 0.01)
        XCTAssertEqual(DashRoute.meters(atCorner, corner), 0, accuracy: 0.01)
        XCTAssertEqual(DashRoute.meters(afterEnd, end), 0, accuracy: 0.01)
        XCTAssertEqual(route.upcoming(from: route.distance, length: 100).count, 1)
    }

    func testProgressAlongTheRoute() {
        let route = route()
        // Half way along the first leg, 20 m north of it.
        let here = CLLocationCoordinate2D(latitude: 13.0 + 20 / 110_540, longitude: 100.005)
        let progress = route.progress(at: here, hint: nil)
        XCTAssertEqual(progress.segment, 0)
        XCTAssertEqual(progress.offRoute, 20, accuracy: 2)
        XCTAssertEqual(progress.nextStep, 1)
        XCTAssertEqual(progress.distanceToNextStep, route.steps[1].startDistance / 2, accuracy: 10)
        XCTAssertEqual(progress.remainingDistance, route.distance - route.steps[1].startDistance / 2, accuracy: 10)
        XCTAssertEqual(progress.remainingTime, 300 * progress.remainingDistance / route.distance, accuracy: 0.1)

        let upcoming = route.upcoming(from: progress.distanceAlong, length: 3000)
        XCTAssertEqual(upcoming.count, 3) // where we are on the line, the corner, the end
    }

    func testFarFromTheRouteIsOffRoute() {
        let away = CLLocationCoordinate2D(latitude: 13.0 - 300 / 110_540, longitude: 100.005)
        XCTAssertGreaterThan(route().progress(at: away, hint: 0).offRoute, 250)
    }

    func testThaiDistancesAndDurations() {
        XCTAssertEqual(DashFormat.distance(47), "50 ม.")
        XCTAssertEqual(DashFormat.distance(349), "350 ม.")
        XCTAssertEqual(DashFormat.distance(1234), "1.2 กม.")
        XCTAssertEqual(DashFormat.distance(15_400), "15 กม.")
        XCTAssertEqual(DashFormat.duration(1100).value, "18")
        XCTAssertEqual(DashFormat.duration(1100).unit, "นาที")
        XCTAssertEqual(DashFormat.duration(3900).value, "1:05")
        XCTAssertEqual(DashFormat.duration(3900).unit, "ชม.")
    }

    func testMotionCarriesTheFixForward() {
        let time = Date()
        let fix = CLLocation(coordinate: start, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 90, speed: 10, timestamp: time)
        var motion = DashMotion()
        _ = motion.step(latest: fix, now: time)
        var position: CLLocationCoordinate2D?
        var course: Double?
        for frame in 1 ... 20 { // one second at 20 fps
            (position, course) = motion.step(latest: fix, now: time.addingTimeInterval(Double(frame) / 20))
        }
        XCTAssertEqual(course ?? -1, 90, accuracy: 0.5)
        let moved = DashRoute.meters(start, try! XCTUnwrap(position))
        XCTAssertGreaterThan(moved, 5, "eases towards where the fix should be by now")
        XCTAssertLessThan(moved, 11)
        XCTAssertGreaterThan(try! XCTUnwrap(position).longitude, start.longitude, "east, along the course")
    }

    func testParkedPositionIgnoresGPSDrift() {
        let time = Date()
        func fix(_ north: Double, _ seconds: Double) -> CLLocation {
            CLLocation(coordinate: start.offsetNorth(north), altitude: 0, horizontalAccuracy: 10,
                       verticalAccuracy: 10, course: -1, speed: 0, timestamp: time.addingTimeInterval(seconds))
        }
        var motion = DashMotion()
        let first = motion.step(latest: fix(0, 0), now: time).0
        var shown: CLLocationCoordinate2D?
        for frame in 1 ... 40 { // two seconds of drift, 6 m either way
            let drift = frame % 2 == 0 ? 6.0 : -6.0
            shown = motion.step(latest: fix(drift, Double(frame / 20)), now: time.addingTimeInterval(Double(frame) / 20)).0
        }
        XCTAssertEqual(DashRoute.meters(try! XCTUnwrap(first), try! XCTUnwrap(shown)), 0, accuracy: 0.01)
    }
}

extension DashNavigationTests {
    /// Phone mounted sideways: its compass reads 270 while the bike heads north. After a short ride
    /// the offset is learned, and stopped, turning the bike 30 degrees turns the map 30 degrees.
    func testCompassLearnsTheMountAndTurnsWhenStopped() {
        let time = Date()
        let start = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        var motion = DashMotion()
        for second in 0 ..< 15 {
            let now = time.addingTimeInterval(Double(second))
            let fix = CLLocation(coordinate: start, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                 course: 0, speed: 10, timestamp: now)
            _ = motion.step(latest: fix, compass: CompassSample(heading: 270, time: now), now: now)
        }
        XCTAssertTrue(motion.compassTrusted)

        let stoppedAt = time.addingTimeInterval(20)
        let parked = CLLocation(coordinate: start, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                course: -1, speed: 0, timestamp: stoppedAt)
        var heading: Double?
        for frame in 0 ..< 40 {
            let now = stoppedAt.addingTimeInterval(Double(frame) / 20)
            heading = motion.step(latest: parked, compass: CompassSample(heading: 300, time: now), now: now).1
        }
        XCTAssertEqual(heading ?? -1, 30, accuracy: 1)
    }

    /// A route that goes 1 km north and comes back down the same road: riding south halfway, we are
    /// on the way back (1.5 km along), not the way out.
    func testProgressFollowsOurDirection() {
        let start = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        let north = CLLocationCoordinate2D(latitude: 13.0 + 1000 / 110_540.0, longitude: 100.0)
        let route = DashRoute(coordinates: [start, north, start], steps: [("", 1000), ("กลับรถ", 1000)],
                              expectedTravelTime: 200)
        let halfway = CLLocationCoordinate2D(latitude: 13.0 + 500 / 110_540.0, longitude: 100.0)
        XCTAssertEqual(route.progress(at: halfway, hint: nil, course: 180).distanceAlong, 1500, accuracy: 10)
        XCTAssertEqual(route.progress(at: halfway, hint: nil, course: 0).distanceAlong, 500, accuracy: 10)
    }

    /// A new route that starts by heading back, or with a U-turn, is turning back.
    func testTurningBackIsRecognised() {
        let here = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        let northward = [here, CLLocationCoordinate2D(latitude: 13.0 + 200 / 110_540.0, longitude: 100.0)]
        let southward = [here, CLLocationCoordinate2D(latitude: 13.0 - 200 / 110_540.0, longitude: 100.0)]
        XCTAssertFalse(DashNavigator.startsByTurningBack(northward, instructions: [("", 0), ("เลี้ยวซ้าย", 200)], course: 0))
        XCTAssertTrue(DashNavigator.startsByTurningBack(southward, instructions: [("", 0)], course: 0))
        XCTAssertTrue(DashNavigator.startsByTurningBack(northward, instructions: [("", 0), ("กลับรถ", 50)], course: 0))
    }

    /// Same road with a new time, or a different road.
    func testSharesRoad() {
        let start = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        let north = CLLocationCoordinate2D(latitude: 13.0 + 3000 / 110_540.0, longitude: 100.0)
        let east = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0 + 3000 / 108_000.0)
        let main = DashRoute(coordinates: [start, north], steps: [("", 3000)], expectedTravelTime: 300)
        let same = DashRoute(coordinates: [start, north], steps: [("", 3000)], expectedTravelTime: 200)
        let other = DashRoute(coordinates: [start, east], steps: [("", 3000)], expectedTravelTime: 200)
        XCTAssertTrue(main.sharesRoad(with: same, over: 5000))
        XCTAssertFalse(main.sharesRoad(with: other, over: 5000))
    }

    /// Spoken distances read the way Thai voices say them.
    func testSpokenDistance() {
        XCTAssertEqual(DashVoice.spokenDistance(230), "250 เมตร")
        XCTAssertEqual(DashVoice.spokenDistance(20), "50 เมตร")
        XCTAssertEqual(DashVoice.spokenDistance(1000), "1 กิโลเมตร")
        XCTAssertEqual(DashVoice.spokenDistance(1460), "1.5 กิโลเมตร")
    }

    /// At 36 km/h a turn is said 1 km ahead, again within 180 m, and at it.
    func testVoiceStages() {
        XCTAssertTrue(DashVoice.stages(distance: 900, speed: 10).early)
        XCTAssertTrue(DashVoice.stages(distance: 150, speed: 10).prepare)
        XCTAssertTrue(DashVoice.stages(distance: 20, speed: 10).now)
        let between = DashVoice.stages(distance: 300, speed: 10)
        XCTAssertFalse(between.early || between.prepare || between.now)
        // Fast, the warning comes earlier: 12 s at 100 km/h is about 333 m.
        XCTAssertTrue(DashVoice.stages(distance: 320, speed: 27.8).prepare)
    }

    /// Saved map tiles sit on a fixed grid: a tile covers itself only, and the level fits the scale.
    func testTileGrid() {
        let latitude = 13.75
        let level = DashTiles.level(metersPerPixel: 1.25, latitude: latitude)
        let key = DashTiles.Key(dark: true, level: level, x: 3000, y: 2000)
        XCTAssertEqual(DashTiles.keys(covering: DashTiles.rect(key), level: level, dark: true), [key])
        let metersPerPixel = DashTiles.width(level) / MKMapPointsPerMeterAtLatitude(latitude) / Double(DashTiles.pixels)
        XCTAssertEqual(metersPerPixel, 1.25, accuracy: 1.25 * 0.1)
        let around = DashTiles.keys(around: MKMapPoint(x: DashTiles.rect(key).midX, y: DashTiles.rect(key).midY),
                                    radius: DashTiles.width(level), level: level, dark: true)
        XCTAssertEqual(around.first, key)
    }
}

private extension CLLocationCoordinate2D {
    func offsetNorth(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + meters / 110_540, longitude: longitude)
    }
}
