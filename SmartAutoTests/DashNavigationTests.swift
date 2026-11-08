import CoreLocation
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

    func testManeuverClassification() {
        XCTAssertEqual(DashManeuver.from(turn: 5, instruction: "", isLast: false), .straight)
        XCTAssertEqual(DashManeuver.from(turn: 30, instruction: "", isLast: false), .slightRight)
        XCTAssertEqual(DashManeuver.from(turn: -90, instruction: "", isLast: false), .left)
        XCTAssertEqual(DashManeuver.from(turn: 150, instruction: "", isLast: false), .sharpRight)
        XCTAssertEqual(DashManeuver.from(turn: 178, instruction: "", isLast: false), .uTurnRight)
        XCTAssertEqual(DashManeuver.from(turn: 90, instruction: "ที่วงเวียน ใช้ทางออกที่ 2", isLast: false), .roundabout)
        XCTAssertEqual(DashManeuver.from(turn: 90, instruction: "", isLast: true), .arrive)
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
}

private extension CLLocationCoordinate2D {
    func offsetNorth(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + meters / 110_540, longitude: longitude)
    }
}
